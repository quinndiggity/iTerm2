@import simd;
@import MetalKit;

#import "iTermMetalDriver.h"

#import "DebugLogging.h"
#import "iTermASCIITexture.h"
#import "iTermBackgroundImageRenderer.h"
#import "iTermBackgroundColorRenderer.h"
#import "iTermBadgeRenderer.h"
#import "iTermBroadcastStripesRenderer.h"
#import "iTermCopyBackgroundRenderer.h"
#import "iTermCursorGuideRenderer.h"
#import "iTermCursorRenderer.h"
#import "iTermMarginRenderer.h"
#import "iTermMetalFrameData.h"
#import "iTermMarkRenderer.h"
#import "iTermMetalRowData.h"
#import "MovingAverage.h"
#import "iTermPreciseTimer.h"
#import "iTermTextRenderer.h"
#import "iTermTextureArray.h"
#import "iTermTextureMap.h"

#import "iTermShaderTypes.h"

// Maybe I could increase this in the future but it's easier to reason about issues during development when it's 1.
static const NSInteger iTermMetalDriverMaximumNumberOfFramesInFlight = 1;

// Here's the order of things and how to interpret the stats we record.
// [main queue]                              - end-to-end  
// drawInMTKView                             |              
//   newFrameData                            | - main thread               
//                                           | | - extract from app
//     Build per-frame state                 | | |                     
//                                           | | -
//    loadFromView                           | |              
//                                           | |
// [private queue]                           | |              
//                                           | - prepare
// prepareRenderers                          | |            
//   create transient state                  | |                       
//   request text stage                      | |                   
//                                           | -
//                                           | - waitForGroup
// [dispatch_group_notify on private queue]  | |                                       
//                                           | -
//                                           | - finalize
// finalize renderers                        | |                 
//   build PIUs                              | |           
//                                           | -           
//                                           | - draw           
//   reallyDrawInView                        | |                  
//                                           | | - get scarce resources
//                                           | | | - get current drawable 
//     get current drawable                  | | | |                   
//                                           | | | -                   
//                                           | | | - get render pass descriptor                   
//     get current render pass descriptor    | | | |                                 
//                                           | | | -                   
//     drawWithDrawable                      | | -                 
//                                           | | - individual draw calls (many stats) 
//       many draw calls                     | | |                  
//                                           | - -
// [GPU completes]                           |                
// completedHandler                          |                 
//   dispatch async to private queue         |                 
//                                           |
// [private queue]                           |                
// complete:                                 |          
//   unlock glyphs                           |                
//   return intermediate texture             |                              
//                                           -

@implementation iTermMetalCursorInfo
@end

@interface iTermMetalDriver()
// This indicates if a draw call was made while busy. When we stop being busy
// and this is set, then we must schedule another draw.
@property (atomic) BOOL needsDraw;
@end

@implementation iTermMetalDriver {
    iTermMarginRenderer *_marginRenderer;
    iTermBackgroundImageRenderer *_backgroundImageRenderer;
    iTermBackgroundColorRenderer *_backgroundColorRenderer;
    iTermTextRenderer *_textRenderer;
    iTermMarkRenderer *_markRenderer;
    iTermBadgeRenderer *_badgeRenderer;
    iTermBroadcastStripesRenderer *_broadcastStripesRenderer;
    iTermCursorGuideRenderer *_cursorGuideRenderer;
    iTermCursorRenderer *_underlineCursorRenderer;
    iTermCursorRenderer *_barCursorRenderer;
    iTermCursorRenderer *_blockCursorRenderer;
    iTermCursorRenderer *_frameCursorRenderer;
    iTermCopyModeCursorRenderer *_copyModeCursorRenderer;
    iTermCopyBackgroundRenderer *_copyBackgroundRenderer;

    // The command Queue from which we'll obtain command buffers
    id<MTLCommandQueue> _commandQueue;

    // The current size of our view so we can use this in our render pipeline
    vector_uint2 _viewportSize;
    CGSize _cellSize;
//    int _iteration;
    int _rows;
    int _columns;
    BOOL _sizeChanged;
    CGFloat _scale;

    dispatch_queue_t _queue;

    iTermMetalFrameDataStatsBundle _stats;
    int _dropped;
    int _total;

    // @synchronized(self)
    int _framesInFlight;
    NSMutableArray *_currentFrames;
    NSTimeInterval _startTime;
    MovingAverage *_fpsMovingAverage;
    NSTimeInterval _lastFrameTime;
}

- (nullable instancetype)initWithMetalKitView:(nonnull MTKView *)mtkView {
    self = [super init];
    if (self) {
        _startTime = [NSDate timeIntervalSinceReferenceDate];
        _marginRenderer = [[iTermMarginRenderer alloc] initWithDevice:mtkView.device];
        _backgroundImageRenderer = [[iTermBackgroundImageRenderer alloc] initWithDevice:mtkView.device];
        _textRenderer = [[iTermTextRenderer alloc] initWithDevice:mtkView.device];
        _backgroundColorRenderer = [[iTermBackgroundColorRenderer alloc] initWithDevice:mtkView.device];
        _markRenderer = [[iTermMarkRenderer alloc] initWithDevice:mtkView.device];
        _badgeRenderer = [[iTermBadgeRenderer alloc] initWithDevice:mtkView.device];
        _broadcastStripesRenderer = [[iTermBroadcastStripesRenderer alloc] initWithDevice:mtkView.device];
        _cursorGuideRenderer = [[iTermCursorGuideRenderer alloc] initWithDevice:mtkView.device];
        _underlineCursorRenderer = [iTermCursorRenderer newUnderlineCursorRendererWithDevice:mtkView.device];
        _barCursorRenderer = [iTermCursorRenderer newBarCursorRendererWithDevice:mtkView.device];
        _blockCursorRenderer = [iTermCursorRenderer newBlockCursorRendererWithDevice:mtkView.device];
        _frameCursorRenderer = [iTermCursorRenderer newFrameCursorRendererWithDevice:mtkView.device];
        _copyModeCursorRenderer = [iTermCursorRenderer newCopyModeCursorRendererWithDevice:mtkView.device];
        _copyBackgroundRenderer = [[iTermCopyBackgroundRenderer alloc] initWithDevice:mtkView.device];

        _commandQueue = [mtkView.device newCommandQueue];
        _queue = dispatch_queue_create("com.iterm2.metalDriver", NULL);
        _currentFrames = [NSMutableArray array];
        _fpsMovingAverage = [[MovingAverage alloc] init];
        iTermMetalFrameDataStatsBundleInitialize(&_stats);
    }

    return self;
}

#pragma mark - APIs

- (void)setCellSize:(CGSize)cellSize gridSize:(VT100GridSize)gridSize scale:(CGFloat)scale {
    scale = MAX(1, scale);
    cellSize.width *= scale;
    cellSize.height *= scale;
    dispatch_async(_queue, ^{
        if (scale == 0) {
            NSLog(@"Warning: scale is 0");
        }
        NSLog(@"Cell size is now %@x%@, grid size is now %@x%@", @(cellSize.width), @(cellSize.height), @(gridSize.width), @(gridSize.height));
        _sizeChanged = YES;
        _cellSize = cellSize;
        _rows = MAX(1, gridSize.height);
        _columns = MAX(1, gridSize.width);
        _scale = scale;
    });
}

#pragma mark - MTKViewDelegate

- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size {
    dispatch_async(_queue, ^{
        // Save the size of the drawable as we'll pass these
        //   values to our vertex shader when we draw
        _viewportSize.x = size.width;
        _viewportSize.y = size.height;
    });
}

// Called whenever the view needs to render a frame
- (void)drawInMTKView:(nonnull MTKView *)view {
    if (_rows == 0 || _columns == 0) {
        DLog(@"  abort: uninitialized");
        [self scheduleDrawIfNeededInView:view];
        return;
    }

    _total++;
    if (_total % 60 == 0) {
        @synchronized (self) {
            NSLog(@"fps=%f (%d in flight)", (_total - _dropped) / ([NSDate timeIntervalSinceReferenceDate] - _startTime), (int)_framesInFlight);
            NSLog(@"%@", _currentFrames);
        }
    }
    BOOL shouldDrop;
    @synchronized(self) {
        shouldDrop = (_framesInFlight == iTermMetalDriverMaximumNumberOfFramesInFlight);
        if (!shouldDrop) {
            _framesInFlight++;
        }
    }
    if (shouldDrop) {
        NSLog(@"  abort: busy (dropped %@%%, number in flight: %d)", @((_dropped * 100)/_total), (int)_framesInFlight);
        _dropped++;
        self.needsDraw = YES;
        return;
    }

    iTermMetalFrameData *frameData = [self newFrameData];
    [frameData loadFromView:view];
    frameData.viewportSize = _viewportSize;

    @synchronized(self) {
        [_currentFrames addObject:frameData];
    }

    [frameData dispatchToPrivateQueue:_queue forPreparation:^{
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (_lastFrameTime) {
            [_fpsMovingAverage addValue:now - _lastFrameTime];
        }
        _lastFrameTime = now;

        [self prepareRenderersWithFrameData:frameData view:view];
    }];
}

#pragma mark - Drawing

// Called on the main queue
- (iTermMetalFrameData *)newFrameData {
    iTermMetalFrameData *frameData = [[iTermMetalFrameData alloc] init];

    [frameData extractStateFromAppInBlock:^{
        frameData.perFrameState = [_dataSource metalDriverWillBeginDrawingFrame];
    }];

    frameData.transientStates = [NSMutableDictionary dictionary];
    frameData.rows = [NSMutableArray array];
    frameData.gridSize = frameData.perFrameState.gridSize;
    frameData.scale = _scale;
    return frameData;
}

- (void)prepareRenderersWithFrameData:(iTermMetalFrameData *)frameData
                                 view:(nonnull MTKView *)view {
    dispatch_group_t group = dispatch_group_create();
    id <MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    iTermRenderConfiguration *configuration = [[iTermRenderConfiguration alloc] initWithViewportSize:_viewportSize scale:frameData.scale];
    __weak __typeof(self) weakSelf = self;
    CGSize cellSize = _cellSize;
    CGFloat scale = _scale;
    [_textRenderer setASCIICellSize:_cellSize
                 creationIdentifier:[frameData.perFrameState metalASCIICreationIdentifier]
                           creation:^NSDictionary<NSNumber *, NSImage *> * _Nonnull(char c, iTermASCIITextureAttributes attributes) {
                               __typeof(self) strongSelf = weakSelf;
                               if (strongSelf) {
                                   static const int typefaceMask = ((1 << iTermMetalGlyphKeyTypefaceNumberOfBitsNeeded) - 1);
                                   iTermMetalGlyphKey glyphKey = {
                                       .code = c,
                                       .isComplex = NO,
                                       .image = NO,
                                       .boxDrawing = NO,
                                       .thinStrokes = !!(attributes & iTermASCIITextureAttributesThinStrokes),
                                       .drawable = YES,
                                       .typeface = (attributes & typefaceMask),
                                   };
                                   BOOL emoji = NO;
                                   return [frameData.perFrameState metalImagesForGlyphKey:&glyphKey
                                                                                     size:cellSize
                                                                                    scale:scale
                                                                                    emoji:&emoji];
                               } else {
                                   return nil;
                               }
                           }];
    CGFloat blending;
    BOOL tiled;
    NSImage *backgroundImage = [frameData.perFrameState metalBackgroundImageGetBlending:&blending tiled:&tiled];
    [_backgroundImageRenderer setImage:backgroundImage blending:blending tiled:tiled];

    [frameData prepareWithBlock:^{
        [commandBuffer enqueue];
        commandBuffer.label = @"Draw Terminal";
        [self.nonCellRenderers enumerateObjectsUsingBlock:^(id<iTermMetalRenderer>  _Nonnull renderer, NSUInteger idx, BOOL * _Nonnull stop) {
            dispatch_group_enter(group);
            [renderer createTransientStateForConfiguration:configuration
                                             commandBuffer:commandBuffer
                                                completion:^(__kindof iTermMetalRendererTransientState * _Nonnull tState) {
                                                    if (tState) {
                                                        frameData.transientStates[NSStringFromClass(renderer.class)] = tState;
                                                        [self updateRenderer:renderer
                                                                       state:tState
                                                                   frameData:frameData];
                                                    }
                                                    dispatch_group_leave(group);
                                                }];
        }];
        VT100GridSize gridSize = frameData.gridSize;

        // We need frameData's intermediateRenderPassDescriptor to be initialized before creating
        // tstate's for subsequent objects. This assertion is there to make sure the tState exists,
        // with the assumption its IRPD is set prior to creation if it should exist.
        assert(frameData.transientStates[NSStringFromClass(_backgroundImageRenderer.class)]);

        iTermCellRenderConfiguration *cellConfiguration = [[iTermCellRenderConfiguration alloc] initWithViewportSize:_viewportSize
                                                                                                               scale:frameData.scale
                                                                                                            cellSize:_cellSize
                                                                                                            gridSize:gridSize
                                                                                               usingIntermediatePass:(frameData.intermediateRenderPassDescriptor != nil)];
        [self.cellRenderers enumerateObjectsUsingBlock:^(id<iTermMetalCellRenderer>  _Nonnull renderer, NSUInteger idx, BOOL * _Nonnull stop) {
            dispatch_group_enter(group);
            [renderer createTransientStateForCellConfiguration:cellConfiguration
                                                 commandBuffer:commandBuffer
                                                    completion:^(__kindof iTermMetalCellRendererTransientState * _Nonnull tState) {
                                                        if (tState) {
                                                            frameData.transientStates[NSStringFromClass([renderer class])] = tState;
                                                            [self updateRenderer:renderer
                                                                           state:tState
                                                                       frameData:frameData];
                                                        }
                                                        dispatch_group_leave(group);
                                                    }];
        }];

        // Renderers may not yet have transient state
        for (int y = 0; y < frameData.gridSize.height; y++) {
            iTermMetalRowData *rowData = [[iTermMetalRowData alloc] init];
            [frameData.rows addObject:rowData];
            rowData.y = y;
            rowData.keysData = [NSMutableData dataWithLength:sizeof(iTermMetalGlyphKey) * _columns];
            rowData.attributesData = [NSMutableData dataWithLength:sizeof(iTermMetalGlyphAttributes) * _columns];
            rowData.backgroundColorData = [NSMutableData dataWithLength:sizeof(vector_float4) * _columns];
            iTermMetalGlyphKey *glyphKeys = (iTermMetalGlyphKey *)rowData.keysData.mutableBytes;
            int drawableGlyphs = 0;
            [frameData.perFrameState metalGetGlyphKeys:glyphKeys
                                            attributes:rowData.attributesData.mutableBytes
                                            background:rowData.backgroundColorData.mutableBytes
                                                   row:y
                                                 width:_columns
                                        drawableGlyphs:&drawableGlyphs];
            rowData.numberOfDrawableGlyphs = drawableGlyphs;
        }
    }];

    __block NSUInteger numberOfRows = 0;
    __block NSRange range = NSMakeRange(0, frameData.rows.count);
    [frameData waitForUpdatesToFinishOnGroup:group
                                     onQueue:_queue
                                    finalize:^{
                                        // All transient states are initialized
                                        numberOfRows = [self finalizeRenderersWithFrameData:frameData range:range];
                                        range.location += numberOfRows;
                                        range.length -= numberOfRows;
                                    }
                                      render:^{
                                          [self reallyDrawInView:view frameData:frameData commandBuffer:commandBuffer];
                                      }];
}

- (void)finalizeCopyBackgroundRendererWithFrameData:(iTermMetalFrameData *)frameData {
    // Copy state
    iTermCopyBackgroundRendererTransientState *copyState =
        frameData.transientStates[NSStringFromClass([_copyBackgroundRenderer class])];
    copyState.sourceTexture = frameData.intermediateRenderPassDescriptor.colorAttachments[0].texture;
}

- (void)finalizeCursorRendererWithFrameData:(iTermMetalFrameData *)frameData {
    // Update glyph attributes for block cursor if needed.
    iTermMetalCursorInfo *cursorInfo = [frameData.perFrameState metalDriverCursorInfo];
#warning TODO Why is the cursor sometimes equal to grid height?
    if (!cursorInfo.frameOnly && cursorInfo.cursorVisible && cursorInfo.shouldDrawText && cursorInfo.coord.y >= 0 && cursorInfo.coord.y < frameData.gridSize.height) {
        iTermMetalRowData *rowWithCursor = frameData.rows[cursorInfo.coord.y];
        iTermMetalGlyphAttributes *glyphAttributes = (iTermMetalGlyphAttributes *)rowWithCursor.attributesData.mutableBytes;
        glyphAttributes[cursorInfo.coord.x].foregroundColor = cursorInfo.textColor;
        glyphAttributes[cursorInfo.coord.x].backgroundColor = simd_make_float4(cursorInfo.cursorColor.redComponent,
                                                                               cursorInfo.cursorColor.greenComponent,
                                                                               cursorInfo.cursorColor.blueComponent,
                                                                               1);
    }
}

- (NSInteger)finalizeTextRendererWithFrameData:(iTermMetalFrameData *)frameData {
    // Update the text renderer's transient state with current glyphs and colors.
    CGFloat scale = frameData.scale;
    iTermTextRendererTransientState *textState =
    frameData.transientStates[NSStringFromClass([_textRenderer class])];

    // Set the background texture if one is available.
    textState.backgroundTexture = frameData.intermediateRenderPassDescriptor.colorAttachments[0].texture;

    // Configure underlines
    iTermMetalUnderlineDescriptor asciiUnderlineDescriptor;
    iTermMetalUnderlineDescriptor nonAsciiUnderlineDescriptor;
    [frameData.perFrameState metalGetUnderlineDescriptorsForASCII:&asciiUnderlineDescriptor
                                                         nonASCII:&nonAsciiUnderlineDescriptor];
    textState.asciiUnderlineDescriptor = asciiUnderlineDescriptor;
    textState.nonAsciiUnderlineDescriptor = nonAsciiUnderlineDescriptor;
    textState.defaultBackgroundColor = frameData.perFrameState.defaultBackgroundColor;
    
    CGSize cellSize = textState.cellConfiguration.cellSize;
    iTermBackgroundColorRendererTransientState *backgroundState =
    frameData.transientStates[NSStringFromClass([_backgroundColorRenderer class])];
    __block NSUInteger numberOfRows = 0;
    [frameData.rows enumerateObjectsUsingBlock:^(iTermMetalRowData * _Nonnull rowData, NSUInteger idx, BOOL * _Nonnull stop) {
        iTermMetalGlyphKey *glyphKeys = (iTermMetalGlyphKey *)rowData.keysData.mutableBytes;
#if ENABLE_ONSCREEN_STATS
        if (idx == 0) {
            iTermMetalGlyphAttributes *attributes = (iTermMetalGlyphAttributes *)rowData.attributesData.bytes;
            char frame[80];
            sprintf(frame, sizeof(frame) - 1, "Frame %d, %d fps", (int)frameData.frameNumber, (int)(1.0 / [_fpsMovingAverage value]));
            for (int i = 0; frame[i]; i++) {
                glyphKeys[i].code = frame[i];
                glyphKeys[i].isComplex = NO;
                glyphKeys[i].image = NO;
                glyphKeys[i].drawable = YES;
                glyphKeys[i].typeface = iTermMetalGlyphKeyTypefaceRegular;

                attributes[i].backgroundColor = simd_make_float4(1.0, 0.0, 0.0, 1.0);
                attributes[i].foregroundColor = simd_make_float4(1.0, 1.0, 1.0, 1.0);
                attributes[i].underlineStyle = iTermMetalGlyphAttributesUnderlineNone;
            }
        }
#endif

        [textState setGlyphKeysData:rowData.keysData
                              count:rowData.numberOfDrawableGlyphs
                     attributesData:rowData.attributesData
                                row:rowData.y
                backgroundColorData:rowData.backgroundColorData
                           creation:^NSDictionary<NSNumber *,NSImage *> * _Nonnull(int x, BOOL *emoji) {
                               return [frameData.perFrameState metalImagesForGlyphKey:&glyphKeys[x]
                                                                                 size:cellSize
                                                                                scale:scale
                                                                                emoji:emoji];
                           }];
        [backgroundState setColorData:rowData.backgroundColorData
                                  row:rowData.y
                                width:frameData.gridSize.width];
        numberOfRows++;
    }];

    // Tell the text state that it's done getting row data.
    [textState willDraw];
    return numberOfRows;
}

// Called when all renderers have transient state
- (NSUInteger)finalizeRenderersWithFrameData:(iTermMetalFrameData *)frameData
                                       range:(NSRange)range {
    // TODO: call setMarkStyle:row: for each mark

    [frameData finalizeCopyBackgroundRendererWithBlock:^{
        [self finalizeCopyBackgroundRendererWithFrameData:frameData];
    }];

    [frameData finalizeCursorRendererWithBlock:^{
        [self finalizeCursorRendererWithFrameData:frameData];
    }];

    __block NSInteger numberOfRows = 0;
    [frameData finalizeTextRendererWithBlock:^{
        numberOfRows = [self finalizeTextRendererWithFrameData:frameData];
    }];

    return numberOfRows;
}

- (void)drawRenderer:(id<iTermMetalRenderer>)renderer
           frameData:(iTermMetalFrameData *)frameData
       renderEncoder:(id<MTLRenderCommandEncoder>)renderEncoder
                stat:(iTermPreciseTimerStats *)stat {
    iTermPreciseTimerStatsStartTimer(stat);

    NSString *className = NSStringFromClass([renderer class]);
    iTermMetalRendererTransientState *state = frameData.transientStates[className];
    ITDebugAssert(state);
    if (!state.skipRenderer) {
        [renderer drawWithRenderEncoder:renderEncoder transientState:state];
    }

    iTermPreciseTimerStatsMeasureAndRecordTimer(stat);
}

- (void)drawCellRenderer:(id<iTermMetalCellRenderer>)renderer
               frameData:(iTermMetalFrameData *)frameData
           renderEncoder:(id<MTLRenderCommandEncoder>)renderEncoder
                    stat:(iTermPreciseTimerStats *)stat {
    iTermPreciseTimerStatsStartTimer(stat);

    NSString *className = NSStringFromClass([renderer class]);
    iTermMetalCellRendererTransientState *state = frameData.transientStates[className];
    ITDebugAssert(state);
    if (!state.skipRenderer) {
        [renderer drawWithRenderEncoder:renderEncoder transientState:state];
    }

    iTermPreciseTimerStatsMeasureAndRecordTimer(stat);
}

- (void)reallyDrawInView:(MTKView *)view
               frameData:(iTermMetalFrameData *)frameData
           commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    DLog(@"  Really drawing");

    [frameData performBlockWithScarceResources:^(MTLRenderPassDescriptor *renderPassDescriptor, id<CAMetalDrawable> drawable) {
        BOOL ok = YES;
        if (drawable == nil) {
            frameData.status = @"nil currentDrawable";
            ok = NO;
        }
        if (renderPassDescriptor == nil) {
            frameData.status = @"nil renderPassDescriptor";
            ok = NO;
        }
        if (!ok) {
            [commandBuffer commit];
            [self complete:frameData];
            NSLog(@"** DRAW FAILED: %@", frameData);
            return;
        }
        drawable.texture.label = @"Drawable";
        [self drawWithDrawable:drawable renderPassDescriptor:renderPassDescriptor frameData:frameData commandBuffer:commandBuffer];
    }];
}

- (void)drawWithDrawable:(id<CAMetalDrawable>)drawable
    renderPassDescriptor:(MTLRenderPassDescriptor *)viewRenderPassDescriptor
               frameData:(iTermMetalFrameData *)frameData
           commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    MTLRenderPassDescriptor *renderPassDescriptor = frameData.intermediateRenderPassDescriptor ?: viewRenderPassDescriptor;
    id<MTLRenderCommandEncoder> renderEncoder;
    if (renderPassDescriptor != nil) {
        renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        renderEncoder.label = frameData.intermediateRenderPassDescriptor ? @"Render background to intermediate" : @"Render All Layers of Terminal";

        // Set the region of the drawable to which we'll draw.
        MTLViewport viewport = {
            -(double)frameData.viewportSize.x,
            0.0,
            frameData.viewportSize.x * 2,
            frameData.viewportSize.y * 2,
            -1.0,
            1.0
        };
        [renderEncoder setViewport:viewport];

        [self drawCellRenderer:_marginRenderer
                     frameData:frameData
                 renderEncoder:renderEncoder
                          stat:&frameData.stats->drawMargins];

        [self drawRenderer:_backgroundImageRenderer
                 frameData:frameData
             renderEncoder:renderEncoder
                      stat:&frameData.stats->drawBGImage];

        [self drawCellRenderer:_backgroundColorRenderer
                     frameData:frameData
                 renderEncoder:renderEncoder
                          stat:&frameData.stats->drawBGColor];

        //        [_broadcastStripesRenderer drawWithRenderEncoder:renderEncoder];
        //        [_badgeRenderer drawWithRenderEncoder:renderEncoder];
        //        [_cursorGuideRenderer drawWithRenderEncoder:renderEncoder];
        //

        iTermMetalCursorInfo *cursorInfo = [frameData.perFrameState metalDriverCursorInfo];
        if (cursorInfo.cursorVisible) {
            switch (cursorInfo.type) {
                case CURSOR_UNDERLINE:
                    [self drawCellRenderer:_underlineCursorRenderer
                                 frameData:frameData
                             renderEncoder:renderEncoder
                                      stat:&frameData.stats->drawCursor];
                    break;
                case CURSOR_BOX:
                    if (cursorInfo.frameOnly) {
                        [self drawCellRenderer:_frameCursorRenderer
                                     frameData:frameData
                                 renderEncoder:renderEncoder
                                          stat:&frameData.stats->drawCursor];
                    } else {
                        [self drawCellRenderer:_blockCursorRenderer
                                     frameData:frameData
                                 renderEncoder:renderEncoder
                                          stat:&frameData.stats->drawCursor];
                    }
                    break;
                case CURSOR_VERTICAL:
                    [self drawCellRenderer:_barCursorRenderer
                                 frameData:frameData
                             renderEncoder:renderEncoder
                                      stat:&frameData.stats->drawCursor];
                    break;
                case CURSOR_DEFAULT:
                    break;
            }
        }

        //        [_copyModeCursorRenderer drawWithRenderEncoder:renderEncoder];

        if (frameData.intermediateRenderPassDescriptor) {
            [renderEncoder endEncoding];
        }
    }

    renderPassDescriptor = viewRenderPassDescriptor;
    if (renderPassDescriptor) {
        if (frameData.intermediateRenderPassDescriptor) {
            renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:viewRenderPassDescriptor];
            renderEncoder.label = @"Copy bg and render text";
            // Set the region of the drawable to which we'll draw.
            MTLViewport viewport = {
                -(double)_viewportSize.x,
                0.0,
                _viewportSize.x * 2,
                _viewportSize.y * 2,
                -1.0,
                1.0
            };
            [renderEncoder setViewport:viewport];
            [self drawRenderer:_copyBackgroundRenderer
                     frameData:frameData
                 renderEncoder:renderEncoder
                          stat:&frameData.stats->drawCopyBG];
        }
        [self drawCellRenderer:_textRenderer
                     frameData:frameData
                 renderEncoder:renderEncoder
                          stat:&frameData.stats->drawText];

        //        [_markRenderer drawWithRenderEncoder:renderEncoder];

        [renderEncoder endEncoding];
        [commandBuffer presentDrawable:drawable];

        int counter;
        static int nextCounter;
        counter = nextCounter++;
        __block BOOL completed = NO;

        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull buffer) {
            frameData.status = @"completion handler, waiting for dispatch";
            dispatch_async(_queue, ^{
                if (!completed) {
                    completed = YES;
                    [self complete:frameData];
                    [self scheduleDrawIfNeededInView:frameData.view];

                    __weak __typeof(self) weakSelf = self;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [weakSelf.dataSource metalDriverDidDrawFrame];
                    });
                }
            });
        }];

        [commandBuffer commit];
    } else {
        frameData.status = @"failed to get a render pass descriptor";
        [commandBuffer commit];
        [self complete:frameData];
    }
}

- (void)complete:(iTermMetalFrameData *)frameData {
    DLog(@"  Completed");

    // Unlock indices and free up the stage texture.
    iTermTextRendererTransientState *textState =
        frameData.transientStates[NSStringFromClass([_textRenderer class])];
    [textState didComplete];

    [_backgroundImageRenderer didFinishWithTransientState:frameData.transientStates[NSStringFromClass([_backgroundImageRenderer class])]];

    DLog(@"  Recording final stats");
    [frameData didCompleteWithAggregateStats:&_stats];

    @synchronized(self) {
        _framesInFlight--;
        @synchronized(self) {
            frameData.status = @"retired";
            [_currentFrames removeObject:frameData];
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self scheduleDrawIfNeededInView:frameData.view];
    });
}

#pragma mark - Updating

- (void)updateRenderer:(id)renderer
                 state:(__kindof iTermMetalRendererTransientState *)tState
             frameData:(iTermMetalFrameData *)frameData {
    id<iTermMetalDriverDataSourcePerFrameState> perFrameState = frameData.perFrameState;
    
    if (renderer == _backgroundImageRenderer) {
        [self updateBackgroundImageRendererWithTransientState:tState withFrameData:frameData];
    } else if (renderer == _backgroundColorRenderer ||
               renderer == _textRenderer ||
               renderer == _markRenderer ||
               renderer == _broadcastStripesRenderer) {
        // Nothing to do here
    } else if (renderer == _marginRenderer) {
        [self updateMarginRendererWithTransientState:tState
                                       perFrameState:perFrameState];
    } else if (renderer == _badgeRenderer) {
        [self updateBadgeRendererWithPerFrameState:perFrameState];
    } else if (renderer == _cursorGuideRenderer) {
        [self updateCursorGuideRendererWithPerFrameState:perFrameState];
    } else if (renderer == _underlineCursorRenderer ||
               renderer == _barCursorRenderer ||
               renderer == _blockCursorRenderer ||
               renderer == _frameCursorRenderer ||
               renderer == _copyBackgroundRenderer) {
        [self updateCursorRendererWithPerFrameState:perFrameState];
    } else if (renderer == _copyModeCursorRenderer) {
        [self updateCopyModeCursorRendererWithPerFrameState:perFrameState];
    }
}

- (void)updateMarginRendererWithTransientState:(iTermMarginRendererTransientState *)marginState
                                 perFrameState:(id<iTermMetalDriverDataSourcePerFrameState>)perFrameState {
    [marginState setColor:perFrameState.defaultBackgroundColor];
}

- (void)updateBackgroundImageRendererWithTransientState:(iTermBackgroundImageRendererTransientState *)tState
                                          withFrameData:(iTermMetalFrameData *)frameData {
    // TODO: Change the image if needed
    frameData.intermediateRenderPassDescriptor = tState.intermediateRenderPassDescriptor;
}

- (void)updateBadgeRendererWithPerFrameState:(id<iTermMetalDriverDataSourcePerFrameState>)perFrameState {
    // TODO: call setBadgeImage: if needed
}

- (void)updateCursorGuideRendererWithPerFrameState:(id<iTermMetalDriverDataSourcePerFrameState>)perFrameState {
    // TODO:
    // [_cursorGuideRenderer setRow:_dataSource.cursorGuideRow];
    // [_cursorGuideRenderer setColor:_dataSource.cursorGuideColor];
}

- (void)updateCursorRendererWithPerFrameState:(id<iTermMetalDriverDataSourcePerFrameState>)perFrameState {
#warning TODO: I think it's a bug to modify a renderer here. Only the transient state should be changed.
    iTermMetalCursorInfo *cursorInfo = [perFrameState metalDriverCursorInfo];
    if (cursorInfo.cursorVisible) {
        switch (cursorInfo.type) {
            case CURSOR_UNDERLINE:
                [_underlineCursorRenderer setCoord:cursorInfo.coord];
                [_underlineCursorRenderer setColor:cursorInfo.cursorColor];
                break;
            case CURSOR_BOX:
                [_blockCursorRenderer setCoord:cursorInfo.coord];
                [_blockCursorRenderer setColor:cursorInfo.cursorColor];
                [_frameCursorRenderer setCoord:cursorInfo.coord];
                [_frameCursorRenderer setColor:cursorInfo.cursorColor];
                break;
            case CURSOR_VERTICAL:
                [_barCursorRenderer setCoord:cursorInfo.coord];
                [_barCursorRenderer setColor:cursorInfo.cursorColor];
                break;
            case CURSOR_DEFAULT:
                break;
        }
    }
}

- (void)updateCopyModeCursorRendererWithPerFrameState:(id<iTermMetalDriverDataSourcePerFrameState>)perFrameState {
    // TODO
    // setCoord, setSelecting:
}

#pragma mark - Helpers

- (NSArray<id<iTermMetalCellRenderer>> *)cellRenderers {
    return @[ _marginRenderer,
              _textRenderer,
              _backgroundColorRenderer,
              _markRenderer,
              _cursorGuideRenderer,
              _underlineCursorRenderer,
              _barCursorRenderer,
              _blockCursorRenderer,
              _frameCursorRenderer,
              _copyModeCursorRenderer ];
}

- (NSArray<id<iTermMetalRenderer>> *)nonCellRenderers {
    return @[ _backgroundImageRenderer,
              _badgeRenderer,
              _broadcastStripesRenderer,
              _copyBackgroundRenderer ];
}

- (void)scheduleDrawIfNeededInView:(MTKView *)view {
    if (self.needsDraw) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.needsDraw) {
                self.needsDraw = NO;
                [view setNeedsDisplay:YES];
            }
        });
    }
}

@end

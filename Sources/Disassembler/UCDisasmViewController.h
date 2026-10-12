#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "UCDisassembler.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, UCDisasmViewMode) {
    UCDisasmViewModeGraph = 0,
};

@interface UCDisasmViewController : UIViewController

@property (nonatomic, assign) UCDisasmViewMode viewMode;

- (instancetype)initWithAddress:(uint64_t)address
                           size:(NSUInteger)size
                          title:(nullable NSString *)title;

- (instancetype)initWithMethod:(Method)method
                         class:(nullable NSString *)className
                      selector:(nullable NSString *)selectorName;

- (instancetype)initWithClass:(Class)cls
                     selector:(SEL)selector
               isClassMethod:(BOOL)isClassMethod;

- (instancetype)initWithFunction:(UCFunction *)function
                           title:(nullable NSString *)title;

@end

@interface UCCFGView : UIView

@property (nonatomic, strong, nullable) NSArray<UCBasicBlock *> *basicBlocks;
@property (nonatomic, copy, nullable) void (^blockTapHandler)(UCBasicBlock *block);
@property (nonatomic, copy, nullable) void (^instructionTapHandler)(UCDisasmInstruction *instruction);
@property (nonatomic, strong, readonly, nullable) NSMutableDictionary<NSNumber *, UIView *> *blockViewMap;

- (void)layoutGraph;

/// Builds block views a few at a time across runloop turns instead of all at
/// once on the main thread. A function with a large number of basic blocks
/// (common in obfuscated or heavily-inlined code) can otherwise take long
/// enough building every instruction-attributed-string card synchronously
/// that the app appears hung — no runloop turn runs, so nothing redraws,
/// including the loading indicator, which is what made it look like it was
/// stuck mid-spin rather than actually working. `progress` is called on the
/// main thread after each batch with a 0...1 fraction; `completion` runs
/// once every block view exists and it's safe to call `layoutGraph`.
- (void)buildBlockViewsAsync:(nullable NSArray<UCBasicBlock *> *)basicBlocks
                     progress:(nullable void (^)(float fraction))progress
                   completion:(nullable void (^)(void))completion;

@end

@interface UCFuncListViewController : UIViewController

- (instancetype)initWithFunctions:(NSArray<UCFunction *> *)functions;

@end

/// Full instruction-level browser for an already annotated function.
/// The browser never re-analyzes the function; it renders the same instruction
/// objects used by the CFG and pseudocode viewers.
@interface UCDisassemblerBrowserViewController : UIViewController

- (instancetype)initWithFunction:(UCFunction *)function
                           title:(nullable NSString *)title;

@end

NS_ASSUME_NONNULL_END

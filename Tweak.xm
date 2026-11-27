//
//  CoolapkADFree.xm
//
//  目标：酷安 16.7.3（com.coolapk.app build 2611121）开屏广告、信息流广告、详情页/评论区广告。
//
//  设计：
//   - 只用 MSHookMessageEx 与 runtime API，不依赖 Logos / substrate 头文件。
//   - 每条 hook 先检查类与方法是否存在；失败只记录，不崩溃（design.md D5）。
//   - 统一日志：NSLog（subsystem 前缀 [CoolapkADFree]）+ <容器>/tmp/CAC.log；
//     安装报告写入 <容器>/tmp/CAC_install_report.txt，便于后续版本适配时先看报告。
//   - 已知事实（analysis/root-cause.md）：16.7.3 的开屏由服务端下发 GM_SPLASH 广告位，
//     且不经过 ObjC 可见开屏类；旧版 BU/ABU 方法名已被改写。本文件覆盖已确证存在的
//     决策层、加载层与信息流数据层；新增链路只需在对应分组里加一行。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdio.h>
#import <stdarg.h>
#import <string.h>
#import <unistd.h>

// ellekit / CydiaSubstrate 导出的 C API。用 C 链接 + IMP 类型声明，
// 避免 Theos/arm64e 头文件里 extern "C++" 声明导致符号名被名字修饰。
#ifdef __cplusplus
extern "C" {
#endif
extern void MSHookMessageEx(Class cls, SEL selector, IMP replacement, IMP *result);
#ifdef __cplusplus
}
#endif

#define CAC_TWEAK_VERSION "1.0.0"

#pragma mark - 日志

// 正式版（默认）：日志能力整体编译期消除 —— 不建文件、不写 NSLog、拦截函数里不做任何字符串处理。
// 调试版（-DCAC_DEBUG）：写 <容器>/tmp/CAC.log + NSLog（含每次命中）与安装报告，用于排障和适配新版本。
#ifdef CAC_DEBUG
static FILE *gLogFile = NULL;
static char gTmpDir[512] = {0};

static void CACOpenLog(void)
{
    if (gLogFile) return;
    NSString *tmp = NSTemporaryDirectory();
    if (!tmp) return;
    strlcpy(gTmpDir, tmp.UTF8String ?: "", sizeof(gTmpDir));
    char path[600];
    snprintf(path, sizeof(path), "%s/CAC.log", gTmpDir);
    gLogFile = fopen(path, "a");
}

static void CACLog(const char *fmt, ...)
{
    char line[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    NSLog(@"[CoolapkADFree] %s", line);
    if (!gLogFile) CACOpenLog();
    if (gLogFile) { fprintf(gLogFile, "%s\n", line); fflush(gLogFile); }
}
#define CACLogHit(...) CACLog(__VA_ARGS__)

static void CACReportReset(void)
{
    if (!gTmpDir[0]) CACOpenLog();
    if (!gTmpDir[0]) return;
    char path[600];
    snprintf(path, sizeof(path), "%s/CAC_install_report.txt", gTmpDir);
    FILE *f = fopen(path, "w");
    if (f) fclose(f);
}

static void CACReport(const char *fmt, ...)
{
    char line[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    CACLog("%s", line);
    if (!gTmpDir[0]) CACOpenLog();
    if (!gTmpDir[0]) return;
    char path[600];
    snprintf(path, sizeof(path), "%s/CAC_install_report.txt", gTmpDir);
    FILE *f = fopen(path, "a");
    if (f) { fprintf(f, "%s\n", line); fclose(f); }
}

#else  // 正式版

// 所有日志入口在编译期变成空语句：调用点连参数都不再求值。
static void CACReportReset(void) {}
#define CACLog(...)        do { } while (0)
#define CACLogHit(...)     do { } while (0)
#define CACReport(...)     do { } while (0)

#endif

#pragma mark - hook 原语

#ifdef CAC_DEBUG
#define CAC_HIT_BUMP(h) do { (h)++; } while (0)
#else
#define CAC_HIT_BUMP(h) do { } while (0)
#endif

static BOOL CACHasInstanceMethod(Class cls, const char *selName)
{
    if (!cls) return NO;
    return class_getInstanceMethod(cls, sel_registerName(selName)) != NULL;
}

/// 命中后返回 0（BOOL/int 型判定方法）。
static BOOL CACHookReturnZero(const char *clsName, const char *selName, const char *tag)
{
    (void)tag;
    Class cls = NSClassFromString([NSString stringWithUTF8String:clsName]);
    if (!cls) { CACReport("%s: MISS class %s", tag, clsName); return NO; }
    if (!CACHasInstanceMethod(cls, selName)) { CACReport("%s: MISS method -%s", tag, selName); return NO; }
    __block int hits __attribute__((unused)) = 0;
    IMP orig = NULL;
    MSHookMessageEx(cls, sel_registerName(selName), imp_implementationWithBlock(^long(id self) {
        CAC_HIT_BUMP(hits);
        CACLogHit("%s HIT(%d)", tag, hits);
        return 0;
    }), &orig);
    CACReport("%s: hooked (was 0x%p)", tag, orig);
    return YES;
}

/// 命中后返回 nil（对象型方法）。
static BOOL CACHookReturnNil(const char *clsName, const char *selName, const char *tag)
{
    Class cls = NSClassFromString([NSString stringWithUTF8String:clsName]);
    if (!cls) { CACReport("%s: MISS class %s", tag, clsName); return NO; }
    if (!CACHasInstanceMethod(cls, selName)) { CACReport("%s: MISS method -%s", tag, selName); return NO; }
    __block int hits __attribute__((unused)) = 0;
    IMP orig = NULL;
    MSHookMessageEx(cls, sel_registerName(selName), imp_implementationWithBlock(^id(id self) {
        CAC_HIT_BUMP(hits);
        CACLogHit("%s HIT(%d) -> nil", tag, hits);
        return nil;
    }), &orig);
    CACReport("%s: hooked (was 0x%p)", tag, orig);
    return YES;
}

/// 命中后丢弃参数再调原实现（数据灌入型方法）。
static BOOL CACHookDropArg(const char *clsName, const char *selName, const char *tag_)
{
    (void)tag_;
    const char *tag __attribute__((unused)) = tag_;
    Class cls = NSClassFromString([NSString stringWithUTF8String:clsName]);
    if (!cls) { CACReport("%s: MISS class %s", tag, clsName); return NO; }
    if (!CACHasInstanceMethod(cls, selName)) { CACReport("%s: MISS method -%s", tag, selName); return NO; }
    __block IMP orig = NULL;
    __block int hits __attribute__((unused)) = 0;
    MSHookMessageEx(cls, sel_registerName(selName), imp_implementationWithBlock(^void(id self, id arg) {
        CAC_HIT_BUMP(hits);
        CACLogHit("%s HIT(%d) (arg dropped)", tag, hits);
        if (orig) ((void (*)(id, SEL, id))orig)(self, sel_registerName(selName), nil);
    }), &orig);
    CACReport("%s: hooked (was 0x%p)", tag, orig);
    return YES;
}

#pragma mark - 通用 block 型 hook

/// 替换带一个 block 参数的方法（如 `-getSplashAdsWithAdsDataBlock:renderMode:`）：
/// 命中时直接以 nil 作为结果回调，让调用方走“无广告”分支。
static BOOL CACHookBlockArg(const char *clsName, const char *selName, unsigned nblocks, const char *tag_)
{
    (void)tag_;
    const char *tag __attribute__((unused)) = tag_;
    Class cls = NSClassFromString([NSString stringWithUTF8String:clsName]);
    if (!cls) { CACReport("%s: MISS class %s", tag, clsName); return NO; }
    if (!CACHasInstanceMethod(cls, selName)) { CACReport("%s: MISS method -%s", tag, selName); return NO; }
    __block IMP orig = NULL;
    __block int hits __attribute__((unused)) = 0;
    IMP block = imp_implementationWithBlock(^void(id self, id b0, id b1) {
        CAC_HIT_BUMP(hits);
        CACLogHit("%s HIT(%d) -> nil callback", tag, hits);
        if (nblocks > 0 && b0) ((void (^)(id))b0)(nil);
    });
    MSHookMessageEx(cls, sel_registerName(selName), block, &orig);
    CACReport("%s: hooked (was 0x%p)", tag, orig);
    return YES;
}

/// 观测型 hook：只记录命中，不改变任何返回值（用于定位渲染宿主）。
static BOOL CACHookObserve(const char *clsName, const char *selName, const char *tag_)
{
    (void)tag_;
    const char *tag __attribute__((unused)) = tag_;
    Class cls = NSClassFromString([NSString stringWithUTF8String:clsName]);
    if (!cls) { CACReport("%s: MISS class %s", tag, clsName); return NO; }
    if (!CACHasInstanceMethod(cls, selName)) { CACReport("%s: MISS method -%s", tag, selName); return NO; }
    __block IMP orig = NULL;
    __block int hits __attribute__((unused)) = 0;
    SEL sel = sel_registerName(selName);
    IMP block = imp_implementationWithBlock(^id(id self) {
        CAC_HIT_BUMP(hits);
        CACLogHit("%s HIT(%d)", tag, hits);
        return orig ? ((id (*)(id, SEL))orig)(self, sel) : nil;
    });
    MSHookMessageEx(cls, sel, block, &orig);
    CACReport("%s: observed", tag);
    return YES;
}

#pragma mark - 开通页诊断（PROBE）

// 诊断阶段使用：不拦截任何广告，只记录“开通页/启动页”相关入口点清单，
// 用于确认广告渲染路径是否在 ObjC 层可见。通过 -DCAC_PROBE 开启。
#ifdef CAC_PROBE
static void CACProbeView(UIView *v, const char *where, int depth)
{
    if (!v || depth > 6) return;
    CACReport("PROBE[%s] depth=%d view=%s frame=%.0f,%.0f,%.0f,%.0f",
              where, depth, NSStringFromClass([v class]).UTF8String,
              v.frame.origin.x, v.frame.origin.y, v.frame.size.width, v.frame.size.height);
    for (UIView *sub in v.subviews) CACProbeView(sub, where, depth + 1);
}


static void CACProbeWindow(UIWindow *w, const char *where)
{
    if (!w) return;
    CACReport("PROBE[%s] window=%s level=%.0f hidden=%d alpha=%.2f root=%s",
              where, NSStringFromClass([w class]).UTF8String, w.windowLevel, w.isHidden, w.alpha,
              NSStringFromClass([w.rootViewController class]).UTF8String);
    UIViewController *vc = w.rootViewController;
    int n = 0;
    while (vc && n++ < 6) {
        CACReport("PROBE[%s]   presented=%s", where, NSStringFromClass([vc class]).UTF8String);
        vc = vc.presentedViewController;
    }
    CACProbeView(w, where, 0);
}

// 延迟 N 毫秒后在主线程抓窗口快照（同一窗口指针，避免跨线程读 UIKit）
static void CACProbeSnapshotAfter(UIWindow *w, double delay, const char *where)
{
    NSString *tagS = [NSString stringWithUTF8String:where];
    __block UIWindow *wb = w;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CACProbeWindow(wb, tagS.UTF8String);
    });
}

static void CACInstallProbe(void)
{
    Class win = NSClassFromString(@"UIWindow");
    // makeKeyAndVisible：调完原实现后，抓当前快照与 +0.8s/+2s 两次快照
    IMP orig = NULL;
    MSHookMessageEx(win, sel_registerName("makeKeyAndVisible"), imp_implementationWithBlock(^void(id self) {
        ((void (*)(id, SEL))orig)(self, sel_registerName("makeKeyAndVisible"));
        CACLog("PROBE UIWindow -makeKeyAndVisible");
        CACProbeWindow((UIWindow *)self, "makeKey");
        CACProbeSnapshotAfter((UIWindow *)self, 0.8, "makeKey+0.8s");
        CACProbeSnapshotAfter((UIWindow *)self, 2.0, "makeKey+2.0s");
    }), &orig);
    CACReport("PROBE: UIWindow -makeKeyAndVisible hooked");

    // 开屏 VC 出现时，抓一次它自己的视图层级
    Class vc = NSClassFromString(@"_TtC10CoolMarket33SplashAdvertisementViewController");
    if (vc) {
        IMP vorig = NULL;
        MSHookMessageEx(vc, sel_registerName("viewDidAppear:"), imp_implementationWithBlock(^void(id self, BOOL animated) {
            ((void (*)(id, SEL, BOOL))vorig)(self, sel_registerName("viewDidAppear:"), animated);
            UIViewController *c = (UIViewController *)self;
            CACLog("PROBE SplashVC appeared");
            CACProbeView(c.view, "splashVC", 0);
            CACProbeSnapshotAfter(c.view.window, 1.0, "splashVC+1s");
        }), &vorig);
        CACReport("PROBE: SplashAdvertisementViewController -viewDidAppear: hooked");
    }
}

#endif

#pragma mark - 信息流诊断（FEEDPROBE）

#ifdef CAC_FEEDPROBE
#import <UIKit/UIKit.h>

static NSMutableSet *gSeen = nil;

static BOOL CACIsAdName(const char *name)
{
    static const char *keys[] = { "Advertisement", "FeedAd", "AdCell", "AdView", "AdManager", "AdLoader", "AdEntity", "AdItem", "AdModel", "AdData",
                                   "EntityList", "FeedEntity", "LiveCard", "CardCell", "CellLayoutSpec", NULL };
    for (int i = 0; keys[i]; i++) if (strstr(name, keys[i])) return YES;
    return NO;
}

// 记录每个方法首次命中（避免刷屏）
// 明确的酷安信息流广告链路类（静态分析得到）
static BOOL CACIsFeedClass(const char *name)
{
    static const char *list[] = {
        "GeneralEntityListFeedAdvertisementManager", "GeneralEntityListFeedAdvertisementLoader",
        "GeneralEntityListFeedAdvertisementCellBaseV4", "GeneralEntityListAdvertisementCellSelector",
        "EntityListFeedAdvertisementLoadTask", "GeneralListFeedAdManagerV26", "GeneralEntityListCollectionView",
        NULL };
    for (int i = 0; list[i]; i++) if (strstr(name, list[i])) return YES;
    return NO;
}

static void CACProbeHit(NSMutableSet *seen, const char *cls, const char *sel)
{
    NSString *k = [NSString stringWithFormat:@"%s -%s", cls, sel];
    @synchronized (seen) {
        if ([seen containsObject:k]) return;
        [seen addObject:k];
    }
    CACLog("FEEDPROBE HIT %s", k.UTF8String);
}

static void CACInstallFeedProbe(void)
{
    gSeen = [NSMutableSet set];
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    int hooked = 0;
    for (unsigned int i = 0; i < count; i++) {
        Class c = classes[i];
        const char *cn = class_getName(c);
        if (!CACIsAdName(cn) && !CACIsFeedClass(cn)) continue;
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(c, &mc);
        for (unsigned int j = 0; j < mc; j++) {
            SEL sel = method_getName(ms[j]);
            const char *sn = sel_getName(sel);
            if (sn[0] == '_' || strstr(sn, "dealloc") || strstr(sn, "cxx_destruct")) continue;
            NSString *clsBuf = [NSString stringWithUTF8String:cn];
            NSString *selBuf = [NSString stringWithUTF8String:sn];
            IMP orig = NULL;
            MSHookMessageEx(c, sel, imp_implementationWithBlock(^void(id self) {
                CACProbeHit(gSeen, clsBuf.UTF8String, selBuf.UTF8String);
            }), &orig);
            hooked++;
            if (hooked > 4000) break;
        }
        free(ms);
        if (hooked > 4000) break;
    }
    free(classes);
    CACReport("FEEDPROBE: hooked %d methods on ad-named classes", hooked);

    // 所有 cell 复用标识 -> 类名（每个标识只记一次），用于反查广告 cell
    static NSMutableSet *idents = nil;
    idents = [NSMutableSet set];
    // cell 复用：直接观察广告 cell 的类名与复用标识
    Class tv = NSClassFromString(@"UITableView");
    Class cv = NSClassFromString(@"UICollectionView");
    SEL ds = sel_registerName("dequeueReusableCellWithIdentifier:forIndexPath:");
    if (tv) {
        IMP o = NULL;
        MSHookMessageEx(tv, ds, imp_implementationWithBlock(^id(id self, NSString *ident, id ip) {
            id cell = o ? ((id (*)(id, SEL, id, id))o)(self, ds, ident, ip) : nil;
            if (cell) {
                const char *cn = class_getName(object_getClass(cell));
                NSString *key = [NSString stringWithFormat:@"TV %s -> %s", ident.UTF8String ?: "?", cn];
                @synchronized (idents) { if (![idents containsObject:key]) { [idents addObject:key]; CACLog("FEEDPROBE CELL %s", key.UTF8String); } }
            }
            return cell;
        }), &o);
    }
    if (cv) {
        IMP o = NULL;
        MSHookMessageEx(cv, ds, imp_implementationWithBlock(^id(id self, NSString *ident, id ip) {
            id cell = o ? ((id (*)(id, SEL, id, id))o)(self, ds, ident, ip) : nil;
            if (cell) {
                const char *cn = class_getName(object_getClass(cell));
                NSString *key = [NSString stringWithFormat:@"CV %s -> %s", ident.UTF8String ?: "?", cn];
                @synchronized (idents) { if (![idents containsObject:key]) { [idents addObject:key]; CACLog("FEEDPROBE CELL %s", key.UTF8String); } }
            }
            return cell;
        }), &o);
    }
    CACReport("FEEDPROBE: cell dequeue hooks installed");
}
#endif

#pragma mark - 信息流诊断 v2（FEEDPROBE2，低风险：只挂 5 个入口）

#ifdef CAC_FEEDPROBE2
static void CACProbeLog(const char *tag)
{
    CACLog("FEEDPROBE2 %s", tag);
}

static void CACInstallFeedProbe2(void)
{
    Class cell = NSClassFromString(@"_TtC10CoolMarket44GeneralEntityListFeedAdvertisementCellBaseV4");
    if (cell) {
        IMP o = NULL;
        MSHookMessageEx(cell, sel_registerName("initWithFrame:"), imp_implementationWithBlock(^id(id self, CGRect f) {
            CACProbeLog("ADCELL initWithFrame");
            return o ? ((id (*)(id, SEL, CGRect))o)(self, sel_registerName("initWithFrame:"), f) : nil;
        }), &o);
        CACReport("FEEDPROBE2: ad cell initWithFrame hooked");
    } else CACReport("FEEDPROBE2: MISS ad cell class");

    Class gm = NSClassFromString(@"_TtC10CoolMarket51GeneralEntityListFeedAdvertisementLoader_GMSelfDraw");
    if (gm) {
        IMP o = NULL;
        MSHookMessageEx(gm, sel_registerName("nativeAdsManagerSuccessToLoad:nativeAds:"), imp_implementationWithBlock(^void(id self, id a1, id a2) {
            CACProbeLog("LOADER GMSelfDraw successToLoad");
            if (o) ((void (*)(id, SEL, id, id))o)(self, sel_registerName("nativeAdsManagerSuccessToLoad:nativeAds:"), a1, a2);
        }), &o);
        CACReport("FEEDPROBE2: GMSelfDraw loader hooked");
    } else CACReport("FEEDPROBE2: MISS GMSelfDraw loader");

    Class tp = NSClassFromString(@"_TtC10CoolMarket46GeneralEntityListFeedAdvertisementLoader_Topon");
    if (tp) {
        IMP o = NULL;
        MSHookMessageEx(tp, sel_registerName("didFinishLoadingADWithPlacementID:"), imp_implementationWithBlock(^void(id self, id pid) {
            CACProbeLog("LOADER Topon didFinishLoading");
            if (o) ((void (*)(id, SEL, id))o)(self, sel_registerName("didFinishLoadingADWithPlacementID:"), pid);
        }), &o);
        CACReport("FEEDPROBE2: Topon loader hooked");
    } else CACReport("FEEDPROBE2: MISS Topon loader");

    Class csj = NSClassFromString(@"CSJNativeAdsManager");
    if (csj) {
        IMP o = NULL;
        MSHookMessageEx(csj, sel_registerName("initWithSlot:"), imp_implementationWithBlock(^id(id self, id slot) {
            CACProbeLog("CSJNativeAdsManager initWithSlot");
            return o ? ((id (*)(id, SEL, id))o)(self, sel_registerName("initWithSlot:"), slot) : nil;
        }), &o);
        IMP o2 = NULL;
        MSHookMessageEx(csj, sel_registerName("loadAdDataWithCount:"), imp_implementationWithBlock(^void(id self, long n) {
            CACProbeLog("CSJNativeAdsManager loadAdDataWithCount");
            if (o2) ((void (*)(id, SEL, long))o2)(self, sel_registerName("loadAdDataWithCount:"), n);
        }), &o2);
        CACReport("FEEDPROBE2: CSJNativeAdsManager hooked");
    } else CACReport("FEEDPROBE2: MISS CSJNativeAdsManager");

    Class gmgr = NSClassFromString(@"GMNativeAdsManager");
    if (gmgr) {
        IMP o = NULL;
        MSHookMessageEx(gmgr, sel_registerName("initWithSlot:"), imp_implementationWithBlock(^id(id self, id slot) {
            CACProbeLog("GMNativeAdsManager initWithSlot");
            return o ? ((id (*)(id, SEL, id))o)(self, sel_registerName("initWithSlot:"), slot) : nil;
        }), &o);
        CACReport("FEEDPROBE2: GMNativeAdsManager hooked");
    } else CACReport("FEEDPROBE2: MISS GMNativeAdsManager");
}
#endif

#pragma mark - 信息流：阻断广告加载（v2）

// 实测 16.7.3 的帖子/详情页广告由 GMNativeAdsManager（GroMore 封装）与 CSJNativeAdsManager
// 发起加载，随后才产生广告 cell。这里直接掐掉“加载”这一步：不调用原实现，广告永远不会到达。
static void CACBlockFeedLoad(void)
{
    Class gm = NSClassFromString(@"GMNativeAdsManager");
    if (gm) {
        IMP o1 = NULL;
        MSHookMessageEx(gm, sel_registerName("loadAdDataWithCount:"), imp_implementationWithBlock(^void(id self, long n) {
            static int c = 0; if (c++ < 5) CACLog("FEEDBLOCK GM loadAdDataWithCount dropped");
        }), &o1);
        IMP o2 = NULL;
        MSHookMessageEx(gm, sel_registerName("loadAdDataWithMediaSlotConfigIDs:sign:"), imp_implementationWithBlock(^void(id self, id ids, id sign) {
            static int c = 0; if (c++ < 5) CACLog("FEEDBLOCK GM loadAdDataWithMediaSlotConfigIDs dropped");
        }), &o2);
        CACReport("FEEDBLOCK: GMNativeAdsManager load blocked");
    } else {
        CACReport("FEEDBLOCK: MISS GMNativeAdsManager");
    }

    Class csj = NSClassFromString(@"CSJNativeAdsManager");
    if (csj) {
        IMP o3 = NULL;
        MSHookMessageEx(csj, sel_registerName("loadAdDataWithCount:"), imp_implementationWithBlock(^void(id self, long n) {
            static int c = 0; if (c++ < 5) CACLog("FEEDBLOCK CSJ loadAdDataWithCount dropped");
        }), &o3);
        IMP o4 = NULL;
        if (class_getInstanceMethod(csj, sel_registerName("loadAdDataWithCount:invokeByPublisher:"))) {
            MSHookMessageEx(csj, sel_registerName("loadAdDataWithCount:invokeByPublisher:"), imp_implementationWithBlock(^void(id self, long n, BOOL b) {
                static int c = 0; if (c++ < 5) CACLog("FEEDBLOCK CSJ loadAdDataWithCount:invokeByPublisher: dropped");
            }), &o4);
        }
        CACReport("FEEDBLOCK: CSJNativeAdsManager load blocked");
    } else {
        CACReport("FEEDBLOCK: MISS CSJNativeAdsManager");
    }
}

#pragma mark - 链路分组

// 开屏 · 决策层：广告有效性 / 最终类型判定
static void CACInstallSplashDecision(void)
{
    CACHookReturnZero("CSJADLoadSplashContext", "isAdValid", "SPLASH.CSJ.isAdValid");
    CACHookReturnZero("CSJADLoadSplashContext", "splashFinalType", "SPLASH.CSJ.splashFinalType");
    CACHookReturnZero("ABUAdPackage", "splashFinalType", "SPLASH.ABU.splashFinalType");
    CACHookReturnZero("BUADLoadSplashContext", "isAdValid", "SPLASH.BU.isAdValid");   // 旧版命名
    CACHookReturnZero("BUSplashAd", "isAdValid", "SPLASH.BU.isAdValid");
    CACHookReturnZero("BUSplashAdView", "canUse", "SPLASH.BU.canUse");                 // 旧版命名
    // 酷安自营开屏（TXAd）：拉取入口与缓存命中入口以 nil 回包处理
    CACHookBlockArg("TXAdSplashManager", "getSplashAdsWithAdsDataBlock:renderMode:", 1, "SPLASH.TX.getSplashAds");
    CACHookBlockArg("TXAdSplashModule", "getSplashAdsWithDataBlock:renderMode:", 1, "SPLASH.TXModule.getSplashAds");
    CACHookBlockArg("TXAdSplashCacheService", "loadSplashResponse:adResponseBlock:isRenderModeCustom:", 1, "SPLASH.TX.cache.load");
}

// 开屏 · 加载层：ABU 聚合选择适配器（16.7.3 方法名被改写）
static void CACInstallSplashLoader(void)
{
    CACHookReturnZero("ABUSplashAdLoader", "isValidAdapter:mediaSlotConfig:", "SPLASH.ABU.isValidAdapter");
    CACHookReturnZero("ABUSplashAdLoader", "Pods_NODuan:mediaSlotConfig:", "SPLASH.ABU.Pods_NODuan");
    CACHookReturnZero("ABUSplashAdLoader", "NULL_ModBu_y:withMediaSlotConfig:", "SPLASH.ABU.NULL_ModBu_y");
    CACHookReturnZero("ABUSplashAdLoader", "Need_ThisIs:mediaSlotConfig:params:", "SPLASH.ABU.Need_ThisIs");
}

// 开屏 · 渲染层兜底：开屏 VC 与 GM 自绘开屏视图
static void CACInstallSplashRender(void)
{
    static const char *vp[] = { "viewDidLoad", "viewWillAppear:", "viewDidAppear:", NULL };
    Class vc = NSClassFromString(@"_TtC10CoolMarket33SplashAdvertisementViewController");
    if (vc) {
        for (int i = 0; vp[i]; i++) {
            if (!CACHasInstanceMethod(vc, vp[i])) { CACReport("SPLASH.VC: MISS -%s", vp[i]); continue; }
            __block IMP orig = NULL;
            __block int hits __attribute__((unused)) = 0;
            const char *tag = vp[i];
            if (tag[strlen(tag) - 1] == ':') {
                MSHookMessageEx(vc, sel_registerName(tag), imp_implementationWithBlock(^void(id self, id arg) {
                    CAC_HIT_BUMP(hits); CACLog("SPLASH.VC -%s HIT(%d)", tag, hits);
                    if (orig) ((void (*)(id, SEL, id))orig)(self, sel_registerName(tag), arg);
                }), &orig);
            } else {
                MSHookMessageEx(vc, sel_registerName(tag), imp_implementationWithBlock(^void(id self) {
                    CAC_HIT_BUMP(hits); CACLog("SPLASH.VC -%s HIT(%d)", tag, hits);
                    if (orig) ((void (*)(id, SEL))orig)(self, sel_registerName(tag));
                }), &orig);
            }
            CACReport("SPLASH.VC -%s: hooked (was 0x%p)", tag, orig);
        }
    } else {
        CACReport("SPLASH.VC: MISS class SplashAdvertisementViewController");
    }
    // GM 自绘开屏与假开屏占位视图：观测是否真的被创建
    CACHookObserve("CoolapkGMSplashView", "initWithFrame:", "SPLASH.GMView.init");
    CACHookObserve("FakeSplashAdvertisementView", "initWithFrame:", "SPLASH.FakeView.init");
}

// 信息流 · 数据层：原生广告数据灌入
static void CACInstallNativeAdData(void)
{
    CACHookDropArg("BUNativeAdsManager", "setAdslot:", "FEED.BU.setAdslot");
    CACHookDropArg("BUNativeAdsManager", "setAdMarkup:", "FEED.BU.setAdMarkup");
    CACHookDropArg("BUNativeAdsManager", "setAdData:", "FEED.BU.setAdData");
    CACHookDropArg("GMNativeAdsManager", "setAdslot:", "FEED.GM.setAdslot");
    CACHookDropArg("CSJNativeAdsManager", "setAdslot:", "FEED.CSJ.setAdslot");
    CACHookDropArg("CSJNativeAdsManager", "setAdMarkup:", "FEED.CSJ.setAdMarkup");
    CACHookDropArg("CSJNativeAdsManager", "setAdData:", "FEED.CSJ.setAdData");
    CACHookDropArg("ABUNativeAdView", "setAdslot:", "FEED.ABU.setAdslot");
    CACHookDropArg("ABUDrawAdView", "setAdslot:", "FEED.ABU.drawSetAdslot");
    CACHookDropArg("ABUDrawAdView", "setAdMarkup:", "FEED.ABU.drawSetAdMarkup");
    CACHookDropArg("GMNativeAdsManager", "setAdMarkup:", "FEED.GM.setAdMarkup");
    CACHookDropArg("GMNativeAdsManager", "setAdData:", "FEED.GM.setAdData");
    CACHookDropArg("GMSplashAd", "setAdslot:", "SPLASH.GMSplashAd.setAdslot");
    CACHookDropArg("GMSplashAd", "setAdMarkup:", "SPLASH.GMSplashAd.setAdMarkup");
    CACHookDropArg("GMSplashAd", "setAdData:", "SPLASH.GMSplashAd.setAdData");
    CACHookDropArg("BUSplashAd", "setAdslot:", "SPLASH.BUSplashAd.setAdslot");
    CACHookDropArg("BUSplashAd", "setAdMarkup:", "SPLASH.BUSplashAd.setAdMarkup");
    CACHookDropArg("BUSplashAd", "setAdData:", "SPLASH.BUSplashAd.setAdData");
}

#pragma mark - 入口

__attribute__((constructor)) static void CACInit(void)
{
    @autoreleasepool {
        NSString *bid = NSBundle.mainBundle.bundleIdentifier;
        if (![bid isEqualToString:@"com.coolapk.app"]) return;
#ifdef CAC_DEBUG
        NSString *ver = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        NSString *build = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"];
#endif
        CACReportReset();
        CACReport("==== CoolapkADFree %s install @ %s (%@/%@) ====", CAC_TWEAK_VERSION, bid.UTF8String, ver, build);
#ifdef CAC_FEEDPROBE2
        CACInstallFeedProbe2();
        CACReport("==== feed probe2 install report end ====");
        return;
#endif
#ifdef CAC_FEEDPROBE
        CACInstallFeedProbe();
        CACReport("==== feed probe install report end ====");
        return;
#endif
#ifdef CAC_PROBE
        // 诊断版本：只观测，不做任何拦截与修改，避免干扰复现。
        CACInstallProbe();
        CACReport("==== probe install report end ====");
        return;
#endif
        CACBlockFeedLoad();
        CACInstallSplashDecision();
        CACInstallSplashLoader();
        CACInstallSplashRender();
        CACInstallNativeAdData();
        CACReport("==== install report end ====");
    }
}

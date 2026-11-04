#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v1.0.84 补丁 B：全屏场景的完整修复

补充 patch_v84.py 未覆盖的两种全屏情况：

情况 1：YouTube 在【同一个 window】内 present 全屏 VC
  → VC 的 view 被加到 window.subviews 末尾（最上层）盖住字幕
  → 已由 bringToFrontIfNeeded 处理

情况 2：YouTube 全屏时【新建了一个 window】
  → 我们的 container 还挂在旧 window 里（旧 window 在下层）→ 完全看不见
  → 需要重新挂载到新的 key window

情况 3：旋转后字幕框跑出屏幕外
  → _userCenter 是绝对坐标，竖屏 (393x852) 拖到 (189,320)，
     转横屏 (852x393) 后 y=320 贴近底边 / 加上高度可能溢出
  → 需要把 container 钳制在宿主 bounds 内
"""
import io
import sys

SRC = "LiveCap.m"


def read(p):
    return io.open(p, encoding="utf-8").read()


def write(p, s):
    io.open(p, "w", encoding="utf-8", newline="\n").write(s)


def must_replace(src, old, new, tag):
    if old not in src:
        print("  [FAIL] %s: 锚点未找到" % tag)
        print("        期望: %r" % old[:140])
        return src, False
    src = src.replace(old, new, 1)
    print("  [OK] %s" % tag)
    return src, True


def main():
    src = read(SRC)
    orig = src
    ok = True

    print("=== v1.0.84 补丁 B：全屏完整修复 ===")

    # -------------------------------------------------------------
    # 1) 新增 bestHostWindow：找出当前该挂载的 window
    # -------------------------------------------------------------
    src, r = must_replace(
        src,
        """// v1.0.84：把字幕 container 提到所在 window 的最顶层。""",
        """// v1.0.84：找出当前应该承载字幕的 window。
// 优先用 key window：YouTube 全屏若新建 window，那个新 window 会成为 key，
// 我们必须跟着搬过去，否则字幕留在旧 window 里被完全盖住。
// 注意：键盘 window 的 windowLevel 很高但不是 key，且不是我们的目标 ——
//       所以只用 key window 判定，不按 windowLevel 挑。
- (UIWindow *)bestHostWindow {
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *key = nil;
    for (UIScene *scene in app.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow && !w.hidden && w.alpha > 0.01) { key = w; break; }
        }
        if (key) break;
    }
    if (key) return key;
    // 兜底：遍历 app.windows 找 key
    for (UIWindow *w in app.windows) {
        if (w.isKeyWindow && !w.hidden) return w;
    }
    // 再兜底：第一个有 rootViewController 的可见 window
    for (UIScene *scene in app.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            if (!w.hidden && w.rootViewController && w.rootViewController.view) return w;
        }
    }
    return nil;
}

// v1.0.84：确保 container 挂在正确的 window 上。
// 全屏新建 window 时把 container 搬过去（保留相对位置比例）。
- (void)ensureInBestWindow {
    if (!_container) return;
    UIWindow *host = [self bestHostWindow];
    if (!host) return;
    if (_container.superview == host) return;
    UIWindow *old = _container.window;
    // 记录迁移前的相对位置比例，迁移后按新窗口尺寸还原
    CGFloat oldW = old ? old.bounds.size.width : 0;
    CGFloat oldH = old ? old.bounds.size.height : 0;
    CGFloat relX = 0.5, relY = 0.5;
    if (oldW > 0 && oldH > 0) {
        relX = _container.center.x / oldW;
        relY = _container.center.y / oldH;
    }
    @try {
        [_container removeFromSuperview];
        [host addSubview:_container];
        // 按新窗口尺寸还原相对位置
        CGPoint c = CGPointMake(relX * host.bounds.size.width,
                                relY * host.bounds.size.height);
        _container.center = c;
        _userCenter = c;
        LCLogF(@"overlay: re-homed to new window (old=%@ new=%@ size=%@)",
               NSStringFromClass([old class]), NSStringFromClass([host class]),
               NSStringFromCGRect(host.bounds));
    } @catch (NSException *e) {
        LCLog(@"overlay: re-home error");
    }
}

// v1.0.84：把字幕 container 提到所在 window 的最顶层。""",
        "新增 bestHostWindow + ensureInBestWindow")
    ok = ok and r

    # -------------------------------------------------------------
    # 2) bringToFrontIfNeeded 里先做 window 校正
    # -------------------------------------------------------------
    src, r = must_replace(
        src,
        """- (void)bringToFrontIfNeeded {
    UIView *parent = _container.superview;
    if (!parent) return;""",
        """- (void)bringToFrontIfNeeded {
    // 先确保挂在正确的 window 上（全屏新建 window 的情况）
    [self ensureInBestWindow];
    UIView *parent = _container.superview;
    if (!parent) return;""",
        "bringToFrontIfNeeded 先校正 window")
    ok = ok and r

    # -------------------------------------------------------------
    # 3) 增加 UIWindowDidBecomeKeyNotification 监听
    # -------------------------------------------------------------
    src, r = must_replace(
        src,
        """    // 尺寸变化：旋转 / 全屏切换都会触发
    [nc addObserverForName:UIWindowDidChangeFrameNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self renderCurrent];
        });
    }];""",
        """    // 尺寸变化：旋转 / 全屏切换都会触发
    [nc addObserverForName:UIWindowDidChangeFrameNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self renderCurrent];
        });
    }];
    // v1.0.84：key window 变化 = 全屏新建了 window → 必须把字幕搬过去
    [nc addObserverForName:UIWindowDidBecomeKeyNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self ensureInBestWindow];
            [self renderCurrent];
            LCLogF(@"overlay: key window changed -> re-homed (super=%@)",
                   NSStringFromCGRect(_container.superview.bounds));
        });
    }];""",
        "新增 key window 变化监听")
    ok = ok and r

    # -------------------------------------------------------------
    # 4) 位置钳制：把 container 限制在宿主 bounds 内
    # -------------------------------------------------------------
    src, r = must_replace(
        src,
        """            CGRect f = _container.frame;
            f.size = CGSizeMake(w, h);
            // 保持中心点不变（用户拖到的位置），只改尺寸
            f.origin = CGPointMake(_userCenter.x - w / 2.0, _userCenter.y - h / 2.0);
            _container.frame = f;
            _userCenter = _container.center;""",
        """            CGRect f = _container.frame;
            f.size = CGSizeMake(w, h);
            // 保持中心点不变（用户拖到的位置），只改尺寸
            f.origin = CGPointMake(_userCenter.x - w / 2.0, _userCenter.y - h / 2.0);
            // v1.0.84：把 container 钳制在宿主 bounds 内。
            // 竖屏 (393x852) 拖到 (189,320)，转横屏 (852x393) 后
            // 320 + 高度/2 可能超出底边 → 字幕被推出屏幕（全屏时看不见）。
            CGFloat minX = w / 2.0;
            CGFloat maxX = MAX(sw - w / 2.0, minX);
            CGFloat minY = h / 2.0;
            CGFloat maxY = MAX(sh - h / 2.0, minY);
            f.origin.x = MIN(MAX(f.origin.x, minX - w / 2.0), maxX - w / 2.0);
            f.origin.y = MIN(MAX(f.origin.y, minY - h / 2.0), maxY - h / 2.0);
            _container.frame = f;
            _userCenter = _container.center;""",
        "位置钳制在宿主 bounds 内")
    ok = ok and r

    if src == orig:
        print("\n没有任何改动！")
        return 1

    write(SRC, src)
    print("\n已写入 %s" % SRC)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

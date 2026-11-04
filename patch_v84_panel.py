#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v1.0.84 面板补丁：新增「识别分片」选项

让用户能直接调 ASR 分片时长来权衡「延迟」与「句子完整度」：
  1.5s —— 延迟最低（~1.7s RTT），但句子容易被切碎
  2.5s —— 默认，平衡
  5.0s —— 句子最完整，但 RTT ~5.6s，延迟明显
"""
import io
import re
import sys

P = "PrefBundle/LiveCapPrefs.m"


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
    src = read(P)
    orig = src
    ok = True

    print("=== v1.0.84 面板补丁 ===")

    # ---- 1) 新增一行 cell：识别分片 ----
    src, r = must_replace(
        src,
        """        } else {
            // v1.0.82：默认只显示中文一行；打开后恢复「英文原文 + 中文翻译」两行
            cell.textLabel.text = @"显示英文原文";""",
        """        } else if (indexPath.row == 4) {
            // v1.0.84：ASR 分片时长（秒）—— 直接影响字幕延迟
            cell.textLabel.text = @"识别分片";
            double cs = [(NSNumber *)LCGet(@"asrChunkSeconds") doubleValue];
            if (cs < 1.0 || cs > 8.0) cs = 2.5;
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.1f 秒", cs];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            // v1.0.82：默认只显示中文一行；打开后恢复「英文原文 + 中文翻译」两行
            cell.textLabel.text = @"显示英文原文";""",
        "新增「识别分片」cell")
    ok = ok and r

    # ---- 2) 点击处理：弹出选择 ----
    src, r = must_replace(
        src,
        """    else if (indexPath.section == 2 && indexPath.row == 2) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"文字颜色"
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleActionSheet];""",
        """    else if (indexPath.section == 2 && indexPath.row == 4) {
        // v1.0.84：ASR 分片时长选择
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"识别分片时长"
                                                                       message:@"分片越短字幕延迟越低，但句子越容易被切断"
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        NSArray *opts = @[@1.5, @2.5, @3.5, @5.0];
        for (NSNumber *v in opts) {
            double s = [v doubleValue];
            NSString *title = [NSString stringWithFormat:@"%.1f 秒%@", s,
                               (s == 2.5 ? @"（推荐）" : @"")];
            [alert addAction:[UIAlertAction actionWithTitle:title
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction *a) {
                LCSet(@(s), @"asrChunkSeconds");
                [self.lc_tv reloadData];
            }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
    else if (indexPath.section == 2 && indexPath.row == 2) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"文字颜色"
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleActionSheet];""",
        "新增「识别分片」点击处理")
    ok = ok and r

    if src == orig:
        print("\n没有任何改动！")
        return 1

    write(P, src)
    print("\n已写入 %s" % P)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

# -*- coding: utf-8 -*-
"""v1.0.82：设置面板新增「显示英文原文」开关（默认关 = 只显示中文一行）"""
import io, sys

P = 'PrefBundle/LiveCapPrefs.m'
src = io.open(P, encoding='utf-8').read()
orig_len = len(src)
errors = []

def sub(old, new, tag, count=1):
    global src
    if old not in src:
        errors.append("未找到片段: %s" % tag); return False
    if src.count(old) != count:
        errors.append("片段 %s 出现 %d 次（期望 %d）" % (tag, src.count(old), count)); return False
    src = src.replace(old, new, count)
    return True

# 1) 第 2 节行数 4 -> 5
sub(
"""    if (section == 0) return 4;
    if (section == 1) return 2;  // 腾讯云 SecretId / SecretKey
    if (section == 2) return 4;
    return 0;""",
"""    if (section == 0) return 4;
    if (section == 1) return 2;  // 腾讯云 SecretId / SecretKey
    if (section == 2) return 5;  // 字号 / 粗体 / 文字颜色 / 背景样式 / 显示英文原文
    return 0;""",
"rows count")

# 2) cell 内容：新增第 5 行「显示英文原文」
sub(
"""        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"文字颜色";
            cell.detailTextLabel.text = [self lc_colorTitle];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = @"背景样式";
            cell.detailTextLabel.text = [self lc_bgStyleTitle];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }""",
"""        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"文字颜色";
            cell.detailTextLabel.text = [self lc_colorTitle];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 3) {
            cell.textLabel.text = @"背景样式";
            cell.detailTextLabel.text = [self lc_bgStyleTitle];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            // v1.0.82：默认只显示中文一行；打开后恢复「英文原文 + 中文翻译」两行
            cell.textLabel.text = @"显示英文原文";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = [(NSNumber *)LCGet(@"showEnglish") boolValue];
            [sw addTarget:self action:@selector(lc_showEnglishChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }""",
"cell row 4")

# 3) 开关回调
sub(
"""- (void)lc_boldChanged:(UISwitch *)sw { LCSet(@(sw.on), @"boldText");""",
"""- (void)lc_boldChanged:(UISwitch *)sw { LCSet(@(sw.on), @"boldText"); }
- (void)lc_showEnglishChanged:(UISwitch *)sw { LCSet(@(sw.on), @"showEnglish");""",
"switch handler")

# 4) 页脚说明补一句
sub(
"""        return @"字幕可长按拖动，位置按 App 记忆（重开 App 回到上次位置）。背景样式：无背景描边 / 半透明黑 / 实黑 / 半透明白 / 毛玻璃。";""",
"""        return @"字幕可长按拖动，位置按 App 记忆（重开 App 回到上次位置）。背景样式：无背景描边 / 半透明黑 / 实黑 / 半透明白 / 毛玻璃。\\n默认只显示中文译文一行；打开「显示英文原文」可恢复上下两行（英文在上、中文在下）。";""",
"footer")

if errors:
    print("补丁失败：")
    for e in errors:
        print("  - " + e)
    sys.exit(1)

io.open(P, 'w', encoding='utf-8', newline='\n').write(src)
print("面板补丁应用成功（%d -> %d 字节）" % (orig_len, len(src)))

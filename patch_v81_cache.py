# -*- coding: utf-8 -*-
"""v1.0.81:
1) 移除 provider 内部的缓存写入（竞速模式下会覆盖胜出结果 / 污染出英文回显）
2) MyMemory 返回 HTML 实体解码（&#39; &quot; &amp; 等）
"""
import io
import sys

PATH = "LiveCap.m"
src = io.open(PATH, encoding="utf-8").read()

REPLACEMENTS = []

# ---- 1) mymemoryTranslate：去掉内部缓存写入 + 解码 HTML 实体 ----
REPLACEMENTS.append((
"""        NSString *result = [content stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        @synchronized(self) {
            _cache[cacheKey] = result;
            if (_cache.count > 300) [_cache removeAllObjects];
        }
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
        }
    }];
    [task resume];""",
"""        NSString *result = [content stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        // MyMemory 会把引号等转成 HTML 实体（&#39; &quot; &amp;），必须还原
        result = LCDecodeHTMLEntities(result);
        // 注意：这里【不】写缓存。
        // 竞速模式下 provider 内部写缓存会出问题：
        //   ① 慢的那家回来后会把胜出的译文覆盖掉；
        //   ② 更糟的是返回「英文回显」的结果被写进缓存，
        //      之后同一句再翻译会直接命中这个坏缓存，永远显示英文。
        // 缓存统一由 raceTranslate 的胜出方写入。
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
        }
    }];
    [task resume];"""))

# ---- 2) openaiTranslate：去掉内部缓存写入 ----
REPLACEMENTS.append((
"""        LCLogF(@"translate: openai response len=%lu text=[%@]", (unsigned long)result.length, result);
        @synchronized(self) {
            _cache[cacheKey] = result;
            if (_cache.count > 300) [_cache removeAllObjects];
        }
        if (completion) {""",
"""        LCLogF(@"translate: openai response len=%lu text=[%@]", (unsigned long)result.length, result);
        // 不在这里写缓存 —— 竞速模式下会覆盖胜出方的结果（见 raceTranslate 注释）
        if (completion) {"""))

# ---- 3) tencentTranslate：同样去掉内部缓存写入 ----
REPLACEMENTS.append((
"""        NSString *result = [content stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        @synchronized(self) {
            _cache[cacheKey] = result;
            if (_cache.count > 300) [_cache removeAllObjects];
        }
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
        }
    }];
    [task resume];
}

// OpenAI 兼容翻译""",
"""        NSString *result = [content stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        // 同样不在 provider 内部写缓存，统一由竞速层负责
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
        }
    }];
    [task resume];
}

// OpenAI 兼容翻译"""))

# ---- 4) 新增 HTML 实体解码辅助函数（放在语言代码辅助函数附近） ----
REPLACEMENTS.append((
"""// 语言代码：BCP-47 -> MyMemory 格式（zh 用 zh-CN，其余取前缀）
static NSString *LCShortLang(NSString *lc) {""",
"""// MyMemory 会把 ' " & < > 转成 HTML 实体，直接上屏会显示成 &#39; 这种乱码。
// 这里做一次还原（只处理常见的几种，避免引入 NSAttributedString 的额外依赖开销）。
static NSString *LCDecodeHTMLEntities(NSString *s) {
    if (!s.length) return s;
    if ([s rangeOfString:@"&"].location == NSNotFound) return s;
    NSMutableString *m = [s mutableCopy];
    NSDictionary *map = @{
        @"&#39;": @"'", @"&apos;": @"'", @"&quot;": @"\\"",
        @"&amp;":  @"&",  @"&lt;":   @"<", @"&gt;":   @">",
        @"&#34;": @"\\"", @"&nbsp;": @" ",
    };
    for (NSString *k in map) {
        [m replaceOccurrencesOfString:k withString:map[k]
                               options:NSLiteralSearch range:NSMakeRange(0, m.length)];
    }
    return [m copy];
}

// 语言代码：BCP-47 -> MyMemory 格式（zh 用 zh-CN，其余取前缀）
static NSString *LCShortLang(NSString *lc) {"""))

for old, new in REPLACEMENTS:
    if old not in src:
        print("ERROR: anchor not found:\n%s" % old[:200])
        sys.exit(1)
    src = src.replace(old, new, 1)

io.open(PATH, "w", encoding="utf-8", newline="\n").write(src)
print("OK applied %d replacements" % len(REPLACEMENTS))

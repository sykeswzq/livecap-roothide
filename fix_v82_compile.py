# -*- coding: utf-8 -*-
"""修复 v1.0.82 的编译错误：
LiveCap.m:435:80: error: incompatible operand types
    ('void (^)(NSString *__strong)' and 'NSNull * _Nonnull')

根因：`completion ?: [NSNull null]` —— ?: 运算符要求两侧类型一致，
      block 类型与 NSNull* 混用直接编译报错。
修复：统一用 id 承载，并显式 cast 回 block。
"""
import io, sys

P = 'LiveCap.m'
src = io.open(P, encoding='utf-8').read()

old = '''    dispatch_async(_queue, ^{
        [self->_pendingItems addObject:@{@"text": trimmed, @"comp": completion ?: [NSNull null]}];
        const NSUInteger kMaxQueue = 3;
        while (self->_pendingItems.count > kMaxQueue) {
            NSDictionary *dropped = self->_pendingItems.firstObject;
            [self->_pendingItems removeObjectAtIndex:0];
            id dc = dropped[@"comp"];
            LCLogF(@"translate: queue overflow, drop oldest text=[%@]", dropped[@"text"]);
            if (dc != [NSNull null]) {
                void (^dcomp)(NSString *) = dc;
                dispatch_async(dispatch_get_main_queue(), ^{ dcomp(nil); });
            }
        }
        [self pumpQueue];
    });'''

new = '''    dispatch_async(_queue, ^{
        // 注意：completion 是 block 类型，不能写成 completion ?: [NSNull null]
        //   —— ?: 运算符要求两侧类型一致，block 与 NSNull* 混用会编译报错
        //      (incompatible operand types: 'void (^)(NSString *)' and 'NSNull *')
        // 这里统一用 id 承载，取出时再显式 cast 回 block。
        id compBox = completion ? (id)completion : (id)[NSNull null];
        [self->_pendingItems addObject:@{@"text": trimmed, @"comp": compBox}];
        const NSUInteger kMaxQueue = 3;
        while (self->_pendingItems.count > kMaxQueue) {
            NSDictionary *dropped = self->_pendingItems.firstObject;
            [self->_pendingItems removeObjectAtIndex:0];
            id dc = dropped[@"comp"];
            LCLogF(@"translate: queue overflow, drop oldest text=[%@]", dropped[@"text"]);
            if (dc && dc != [NSNull null]) {
                void (^dcomp)(NSString *) = (void (^)(NSString *))dc;
                dispatch_async(dispatch_get_main_queue(), ^{ dcomp(nil); });
            }
        }
        [self pumpQueue];
    });'''

if old not in src:
    print("未找到目标片段")
    sys.exit(1)

src = src.replace(old, new, 1)

# 同样的 ?: 类型混用问题也检查 pumpQueue 的取值处
old2 = '''    id rawComp = item[@"comp"];
    void (^comp)(NSString *) = (rawComp != [NSNull null]) ? rawComp : nil;'''
new2 = '''    id rawComp = item[@"comp"];
    void (^comp)(NSString *) = nil;
    if (rawComp && rawComp != [NSNull null]) {
        comp = (void (^)(NSString *))rawComp;
    }'''
if old2 in src:
    src = src.replace(old2, new2, 1)
    print("  + pumpQueue 取值处也修正")
else:
    print("  (pumpQueue 取值处已是安全写法，无需改)")

io.open(P, 'w', encoding='utf-8', newline='\n').write(src)
print("编译错误修复完成")

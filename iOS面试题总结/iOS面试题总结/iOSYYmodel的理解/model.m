//
//  model.m
//  iOS面试题总结
//
//  Created by Mobiyun on 2017/11/24.
//  Copyright © 2017年 冀凯旋. All rights reserved.
//

#import "model.h"
#import <objc/runtime.h>

@interface model ()

@property(strong, nonatomic) NSMutableArray *m_keyArrays;

@end

@implementation model


- (NSMutableArray *)m_keyArrays{

    if (_m_keyArrays == nil) {
        _m_keyArrays = [NSMutableArray new];
    }
    return _m_keyArrays;
}



+ (instancetype)allocWithZone:(struct _NSZone *)zone{
    
    model *mo = [[model allocWithZone:zone] init];
   
    return mo;
}

- (void)initSepModel:(NSDictionary *)dic{
    [_m_keyArrays removeAllObjects];

    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList([self class], &count);
    
    for (NSInteger i = 0; i < count; i ++) {
        Ivar ivar = ivars[i];
        NSString *key = [NSString stringWithUTF8String:ivar_getName(ivar)];
        [self.m_keyArrays addObject:key];
        if (i + 1 == count) {
            [self setSelModelOnDic:dic];
        }
    }
    
}

- (void)setSelModelOnDic:(NSDictionary *)dic{
    
    
    [dic enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
        key = [@"_" stringByAppendingString:key];
        
        if ([self.m_keyArrays containsObject:key]) {
            
        }else{
            
        }


    }];
    
    [[dic allKeys] enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        
    }];

}




@end

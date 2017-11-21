//
//  iOSYYmodel的理解.m
//  iOS面试题总结
//
//  Created by Mobiyun on 2017/11/21.
//  Copyright © 2017年 冀凯旋. All rights reserved.
//

#import "iOSYYmodel的理解.h"

@implementation iOSYYmodel___

/**
 
 · YYClassInfo 主要将 Runtime 层级的一些结构体封装到 NSObject 层级以便调用。
 · NSObject+YYModel 负责提供方便调用的接口以及实现具体的模型转换逻辑（借助 YYClassInfo 中的封装）。
 
 YYClassInfo            Runtime
 YYClassIvarInfo	objc_ivar
 YYClassMethodInfo	objc_method
 YYClassPropertyInfo	property_t
 YYClassInfo            objc_class
 
 
        YYClassIvarInfo && objc_ivar        对 Runtime 层 objc_ivar 结构体的封装，objc_ivar 是 Runtime 中表示变量的结构体。
        YYClassMethodInfo && objc_method    对 Runtime 中 objc_method 的封装，objc_method 在 Runtime 是用来定义方法的结构体。
        YYClassPropertyInfo && property_t   对 property_t 的封装，property_t 在 Runtime 中是用来表示属性的结构体。
        YYClassInfo && objc_class           封装了 objc_class，objc_class 在 Runtime 中表示一个 Objective-C 类。

 
 
 
 
 */


@end

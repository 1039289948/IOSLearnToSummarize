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

 
 NS_ASSUME_NONNULL_BEGIN / NS_ASSUME_NONNULL_END
 为了防止写一大堆 nonnull(不可为nil)，Foundation 还提供了一对儿宏，包在里面的对象默认加 nonnull 修饰符，只需要把 nullable 的指出来就行
 
 #define force_inline inline attribute((always_inline))
 
 __attribute__((always_inline))的意思是强制内联，所有加了__attribute__((always_inline))的函数再被调用时不会被编译成函数调用而是直接扩展到调用函数体内，比如我定义了函数
 __attribute__((always_inline)) void a()
 void b()｛a();｝
 b调用a函数的汇编代码不会是跳转到a执行，而是a函数的代码直接在b内成为b的一部分。
 
 
 YYClassInfo 对 Runtime 层在 JSON 模型转换中需要用到的结构体的封装，那么 NSObject+YYModel 在 YYModel 中担当的责任则是利用 YYClassInfo 层级封装好的类切实的执行 JSON 模型之间的转换逻辑，并且提供了无侵入性的接口。
 
 force_inline 这种代码技巧，我说过我在写完 YYModel 或者攒到足够多的时候会主动拿出来与大家分享这些代码技巧，不过这里大家通过字面也不难理解，就是强制内联。
 
 
 NSDictionary to Model 过程中
 
 // 为字典中的每个键值对调用 ModelSetWithDictionaryFunction
 // 这句话是核心代码，一般情况下就是靠 ModelSetWithDictionaryFunction 通过字典设置模型
 // 这句话是核心代码， ModelSetValueForProperty 函数是为模型中的属性赋值的实现方法
 
 
 yy_modelSetWithDictionary，将字典转模型
 
                                                <-------------------------------------------------------------------------------------------------------------------
 字典转model的流程                                |                                                                                                                   |
                                      根据字典初始化模型的实现方法                           字典键值对建模                                   model进行赋值                  |
 yy_modelWithDictionary ----->>>>>> yy_modelSetWithDictionary ---------->>>>>>> ModelSetWithDictionaryFunction ---------->>>>>>> ModelSetValueForProperty ---------
 
                                            入参校验                                                                                根据属性元类型划分代码逻辑
                                    初始化模型元以及映射表校验                                                    如果属性元是 CNumber 类型，即 int、uint 之类，则使用 ModelSetNumberToProperty 赋值
                                初始化模型设置上下文 ModelSetContext                                      如果属性元属于 NSType 类型，即 NSString、NSNumber 之类，则根据类型转换中可能涉及到的对应类型做逻辑判断并赋值
                        为字典中的每个键值对调用 ModelSetWithDictionaryFunction             如果属性元不属于 CNumber 和 NSType，则猜测为 id，Class，SEL，Block，struct、union、char[n]，void 或 char 类型并且做出相应的转换和赋值
                                        检验转换结果                                                                  在赋值转化过程中会多次使用yy_modelSetWithDictionary函数，进行递归赋值
 
 
 
 */


/**
 Model to JSON
 
 */

/**
 YYModel的优势
 
    缓存 --> Model JSON 转换过程中需要很多类的元数据，如果数据足够小，则全部缓存到内存中。
    查表 --> 当遇到多项选择的条件时，要尽量使用查表法实现，比如 switch/case，C Array，如果查表条件是对象，则可以用 NSDictionary 来实现。
    避免 KVC --> Key-Value Coding 使用起来非常方便，但性能上要差于直接调用 Getter/Setter，所以如果能避免 KVC 而用 Getter/Setter 代替，性能会有较大提升。
    避免 Getter/Setter 调用 --> 如果能直接访问 ivar，则尽量使用 ivar 而不要使用 Getter/Setter 这样也能节省一部分开销。
    避免多余的内存管理方法 --> {
            在 ARC 条件下，默认声明的对象是 strong 类型的，赋值时有可能会产生 retain/release 调用，如果一个变量在其生命周期内不会被释放，则使用 unsafe_unretained 会节省很大的开销。
            访问具有 weak 属性的变量时，实际上会调用 objc_loadWeak() 和 objc_storeWeak() 来完成，这也会带来很大的开销，所以要避免使用 weak 属性。
            创建和使用对象时，要尽量避免对象进入 autoreleasepool，以避免额外的资源开销。

    }
    遍历容器类时，选择更高效的方法 --> {
        相对于 Foundation 的方法来说，CoreFoundation 的方法有更高的性能，用 CFArrayApplyFunction() 和 CFDictionaryApplyFunction() 方法来遍历容器类能带来不少性能提升，但代码写起来会非常麻烦。
    }
    尽量用纯 C 函数、内联函数--> 使用纯 C 函数可以避免 ObjC 的消息发送带来的开销。如果 C 函数比较小，使用 inline 可以避免一部分压栈弹栈等函数调用的开销。
    减少遍历的循环次数 --> 在 JSON 和 Model 转换前，Model 的属性个数和 JSON 的属性个数都是已知的，这时选择数量较少的那一方进行遍历，会节省很多时间。
 
 */















































@end

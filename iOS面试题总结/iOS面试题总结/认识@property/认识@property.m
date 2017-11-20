//
//  认识@property.m
//  iOS面试题总结
//
//  Created by Mobiyun on 2017/11/20.
//  Copyright © 2017年 冀凯旋. All rights reserved.
//

#import "认识@property.h"

@interface ___property ()

@property (atomic, retain) NSDictionary *m_Dic;
@property (nonatomic, copy) NSDictionary *m_listDc;

@end

@implementation ___property

/**
    原子性:atomic&nonatomic
    
        atomic:原子性，这个属性是默认的，通过在setter中加@synchronized(self)保证数据数据的读写安全，需要注意的是，但它不是线程安全的
        nonatomic:非原子性，就是不加锁
 
        readwrite:可读写属性，默认属性，允许编译器@synthesize自动合成
        readonly:只读属性，不生成setter
 
        assign用于值类型，如int、float、double和NSInteger，CGFloat等表示单纯的赋值，简单覆盖原值，没有多余的操作
 
        unsafe_unretained
 
        同assign一样，但是对象销毁后，属性指针并不等于nil而是指向了一块野地址，形成野指针。如果访问，则会出现BAD_ACCESS
 
    
        strong/retain
 
        id类型及对象类型的所有权修饰符。strong是在iOS引入ARC的时候引入的关键字，是retain的一个可选的替代。表示实例变量对传入的对象要有所有权关系，即强引用。strong跟retain的意思相同并产生相同的代码，但是语意上strong更能体现对象的关系。作用是在setter中，对新值retain，对旧值release，并返回新值
 

        weak
        使用范围同strong。区别在于在setter方法中，对传入的对象不进行引用计数加1的操作，即对传入的对象没有所有权
 
        copy
        会将修饰的结果copy一份，重新保存。所以通常用于修饰NSString/NSArray/NSDictionary的属性保护封装性。因为多态性，父类指针可以指向子类指针，如果给一个上述不可变属性赋值了他们的子类，那么在子类发生增删时，同样会影响了当前属性的值，违背了不可变的初衷，使程序变的不可控。而mutable类型copy操作后，就会保存当前的值储存，成为不可变的类型(immutable)。
 
 
 */

/**
 atomic通过加锁@synchronized(self)来保障读写安全，并且在getter中引用计数同样会 +1，来向调用者保证这个对象会一直存在。假如不这样做，如有另一个线程调setter可能会出现线程竞态，导致引用计数降到0，原来那个对象就释放掉了
 */
- (NSDictionary *)m_Dic{

    NSDictionary *retval = nil;
    @synchronized (self) {
        retval = [[_m_Dic retain] autorelease];
    }
    return retval;
}

- (void)setDic:(NSDictionary *)m_newDic{
    
    @synchronized (self) {
        [_m_Dic release];
        _m_Dic = [m_newDic retain];
    }

}


-(instancetype)init{

    if (self = [super init]) {
        
    }
    return self;
}




@end

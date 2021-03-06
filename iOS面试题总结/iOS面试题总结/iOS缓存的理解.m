//
//  iOS缓存的理解.m
//  iOS面试题总结
//
//  Created by Mobiyun on 2017/11/16.
//  Copyright © 2017年 冀凯旋. All rights reserved.
//

#import "iOS缓存的理解.h"

@interface iOS_____ ()

@end

@implementation iOS_____

- (void)viewDidLoad {
    [super viewDidLoad];
    
    /**
     
     NSCache 是苹果提供的一个简单的内存缓存，API类似NSDictionary，但是他是线程安全的。底层直接调用了直接调用了 libcache.dylib，通过pthread_mutex完成
     NSURLCache 是苹果提供的一个简单的磁盘缓存，基于SQLite开发，基于数据库的缓存可以很好的支持元数据、扩展方便、数据统计速度快，也很容易实现 LRU 或其他淘汰算法
     iOS缓存的问题
        
        iOS缓存一般都会放到沙盒目录下的/Library/Caches目录下。分为内存缓存，跟硬盘缓存
     
        内存缓存，可以说是闪存，当APP运行的时候，内存中的缓存，会保留，并能正常的使用，当APP发生闪退，或是退出重新进入的时候，内存缓存，就会被清空！
        硬盘缓存：可以说是物理缓存，只有APP删掉或手动删除沙盒中的缓存文件，磁盘中的缓存才会被清空
     
     
        APP再发送网络请求的时候，post是不会做缓存处理，get会做缓存处理·
        
            一般用NSURLCache来进行缓存数据。在ios5之前，只支持内存缓存。在IOS5之后，支持内存缓存和硬盘缓存
            根据一个NSURLRequest缓存一个NSCacheURLResponse
     
     */
    
    
    
    /**
     
     YYMemoryCache 是内存缓存，优化了同步访问的性能，用 互斥锁 来保证线程安全。另外，缓存内部用双向链表和 NSDictionary 实现了 LRU 淘汰算法，相对于上面几个算是一点进步吧。{
        pthread_mutex_t 互斥锁
     }
     YYDiskCache   是采用的 SQLite 配合文件的存储方式，但得益于 SQLite 存储的元数据，YYDiskCache 实现了 LRU 淘汰算法、更快的数据统计，更多的容量控制选项。！{
     
        #define Lock() dispatch_semaphore_wait(self->_lock, DISPATCH_TIME_FOREVER)
        #define Unlock() dispatch_semaphore_signal(self->_lock)
     
     }
     
     YYMemoryCache使用了互斥锁来实现多线程访问数据的同步性，YYDiskCache使用了信号量来实现，
     
     
     

     
     YYCache 是对内存缓存以及磁盘缓存的所有封装，方便开发使用
     YYDiskCache 是对磁盘缓存（文件缓存）做的一次封装
     YYMemoryCache 是对内存缓存做的封装
     YYKVStorage 是对实现YYDiskCache 文件缓存的底层实现
     
     常用的缓存替换算法如下:
     
     FIFO（先进先出算法）：这种算法选择最先被缓存的数据为被替换的对象，即当缓存满的时候，应当把最先进入缓存的数据给淘汰掉。它的优点是比较容易实现，但是没有反映程序的局部性。因为被淘汰的数据可能会在将来被频繁地使用。
     LFU(近期最少使用算法）：这种算法基于“如果一个数据在最近一段时间内使用次数很少，那么在将来一段时间内被使用的可能性也很小”的思路。这是一种非常合理的算法，正确地反映了程序的局部性，因为到目前为止最少使用的缓存数据，很可能也是将来最少要被使用的缓存数据。但是这种算法实现起来非常困难，每个数据块都有一个引用计数，所有数据块按照引用计数排序，具有相同引用计数的数据块则按照时间排序。所以该算法的内存消耗和性能消耗较高
     LRU算法（最久没有使用算法）：该算法根据数据的历史访问记录来进行淘汰数据，其核心思想是“如果数据最近被访问过，那么将来被访问的几率也更高”。它把LFU算法中要记录数量上的”多”与”少”简化成判断”有”与”无”，因此，实现起来比较容易，同时又能比较好地反映了程序局部性规律。
     
     */

}



- (void)YYMemoryCache{


    /**
     
     YYMemoryCache是YYCache中进行有关内存缓存操作的类，它采用了LRU算法来进行缓存替换。

     YYMemoryCache采用了两种数据结构：
        双向链表：用以实现LRU算法，靠近链表头部的数据使用频率高，靠近尾部的数据则使用频率低，可以被替换掉。
        字典：采用key-value的方式，可以快速的读取缓存中的数据
     
    
     
     */
    
    
}



























































@end

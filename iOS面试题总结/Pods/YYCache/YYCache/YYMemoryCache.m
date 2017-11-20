//
//  YYMemoryCache.m
//  YYCache <https://github.com/ibireme/YYCache>
//
//  Created by ibireme on 15/2/7.
//  Copyright (c) 2015 ibireme.
//
//  This source code is licensed under the MIT-style license found in the
//  LICENSE file in the root directory of this source tree.
//

#import "YYMemoryCache.h"
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <pthread.h>


static inline dispatch_queue_t YYMemoryCacheGetReleaseQueue() {
    return dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0);
}

/**
 A node in linked map.
 Typically, you should not use this class directly.
 链表节点，缓存元数据的结构
 链表中的节点单元是_YYLinkedMapNode对象，该对象封装了缓存数据的信息
 */
@interface _YYLinkedMapNode : NSObject {
    @package
    __unsafe_unretained _YYLinkedMapNode *_prev; // retained by dic 上一节点指针
    __unsafe_unretained _YYLinkedMapNode *_next; // retained by dic 下一节点指针
    id _key; //缓存数据key
    id _value; //缓存数据value
    NSUInteger _cost; //节点占用大小
    NSTimeInterval _time; //节点操作时间戳
}
@end

@implementation _YYLinkedMapNode
@end


/**
 A linked map used by YYMemoryCache.
 It's not thread-safe and does not validate the parameters.
 
 Typically, you should not use this class directly.
 
 缓存区域，链表与字典的结合
 负责实现缓存和LRU的功能
 */
@interface _YYLinkedMap : NSObject {
    @package
    CFMutableDictionaryRef _dic; // do not set object directly 哈希字典，存放缓存数据
    NSUInteger _totalCost;      //缓存总大小
    NSUInteger _totalCount;     //缓存节点总个数
    _YYLinkedMapNode *_head; // MRU, do not change it directly 链表头
    _YYLinkedMapNode *_tail; // LRU, do not change it directly 链表尾
    BOOL _releaseOnMainThread;  //是否主线程释放
    BOOL _releaseAsynchronously;//是否异步释放
}

/// Insert a node at head and update the total cost.
/// Node and node.key should not be nil.
- (void)insertNodeAtHead:(_YYLinkedMapNode *)node;

/// Bring a inner node to header.
/// Node should already inside the dic.
- (void)bringNodeToHead:(_YYLinkedMapNode *)node;

/// Remove a inner node and update the total cost.
/// Node should already inside the dic.
- (void)removeNode:(_YYLinkedMapNode *)node;

/// Remove tail node if exist.
- (_YYLinkedMapNode *)removeTailNode;

/// Remove all node in background queue.
- (void)removeAll;

@end

@implementation _YYLinkedMap

- (instancetype)init {
    self = [super init];
    _dic = CFDictionaryCreateMutable(CFAllocatorGetDefault(), 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    _releaseOnMainThread = NO;
    _releaseAsynchronously = YES;
    return self;
}

- (void)dealloc {
    CFRelease(_dic);
}
// 该方法首先将需要新插入的数据节点存入字典中，以节点中的key作为字典的key。然后更新总大小_totalCost和节点总个数_totalCount，将节点置于链表头部。
- (void)insertNodeAtHead:(_YYLinkedMapNode *)node {
    CFDictionarySetValue(_dic, (__bridge const void *)(node->_key), (__bridge const void *)(node)); //存入字典中
    _totalCost += node->_cost; //更新总大小
    _totalCount++; //更新总数
    if (_head) { //节点置于链表头部
        node->_next = _head;
        _head->_prev = node;
        _head = node;
    } else {
        _head = _tail = node;
    }
}

//该方法将节点移动至链表的头部，因为调用该方法的场景是节点已经存在于字典中，所以不需要新加入字典中。
- (void)bringNodeToHead:(_YYLinkedMapNode *)node {
    if (_head == node) return;
    
    if (_tail == node) {
        _tail = node->_prev;
        _tail->_next = nil;
    } else {
        node->_next->_prev = node->_prev;
        node->_prev->_next = node->_next;
    }
    node->_next = _head;
    node->_prev = nil;
    _head->_prev = node;
    _head = node;
}
//将数据节点从字典和链表中删除，同时更新总大小_totalCost和节点总个数_totalCount
- (void)removeNode:(_YYLinkedMapNode *)node {
    CFDictionaryRemoveValue(_dic, (__bridge const void *)(node->_key));
    _totalCost -= node->_cost;
    _totalCount--;
    if (node->_next) node->_next->_prev = node->_prev;
    if (node->_prev) node->_prev->_next = node->_next;
    if (_head == node) _head = node->_next;
    if (_tail == node) _tail = node->_prev;
}
//将链表中的尾部节点删除，同时从字典中删除节点。
- (_YYLinkedMapNode *)removeTailNode {
    if (!_tail) return nil;
    _YYLinkedMapNode *tail = _tail;
    CFDictionaryRemoveValue(_dic, (__bridge const void *)(_tail->_key));
    _totalCost -= _tail->_cost;
    _totalCount--;
    if (_head == _tail) {
        _head = _tail = nil;
    } else {
        _tail = _tail->_prev;
        _tail->_next = nil;
    }
    return tail;
}
//该方法删除链表中所有节点，同时从字典中删除所有节点。
- (void)removeAll {
    _totalCost = 0;
    _totalCount = 0;
    _head = nil;
    _tail = nil;
    if (CFDictionaryGetCount(_dic) > 0) {
        CFMutableDictionaryRef holder = _dic;
        _dic = CFDictionaryCreateMutable(CFAllocatorGetDefault(), 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        
        if (_releaseAsynchronously) {
            dispatch_queue_t queue = _releaseOnMainThread ? dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
            dispatch_async(queue, ^{
                CFRelease(holder); // hold and release in specified queue
            });
        } else if (_releaseOnMainThread && !pthread_main_np()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                CFRelease(holder); // hold and release in specified queue
            });
        } else {
            CFRelease(holder);
        }
    }
}

@end



@implementation YYMemoryCache {
    pthread_mutex_t _lock;  //互斥锁，保证lru只有一个线程访问
    _YYLinkedMap *_lru;     //cache缓存空间
    dispatch_queue_t _queue;//执行清理操作的串行队列
}
//边界检测
/**
 YYCache通过LRU算法处理缓存数据是否超出容量的情况。首先在初始化时，调用_trimRecursively方法，通过dispatch_after方法默认每隔5秒重新调用。
 */
- (void)_trimRecursively {
    __weak typeof(self) _self = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_autoTrimInterval * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        __strong typeof(_self) self = _self;
        if (!self) return;
        [self _trimInBackground]; //在异步队列中执行边界检测
        [self _trimRecursively]; //递归调用本方法
    });
}

- (void)_trimInBackground {
    dispatch_async(_queue, ^{
        [self _trimToCost:self->_costLimit];
        [self _trimToCount:self->_countLimit];
        [self _trimToAge:self->_ageLimit];
    });
}

//判断链表中所有节点占用大小之和totalCost是否大于costLimit，如果超过，则从链表末尾开始删除节点，直到totalCost小于等于costLimit为止
/**
 其中每个节点的cost是人为指定的，默认是0，且costLimit默认是NSUIntegerMax，所以在默认情况下，_trimToCost方法不会删除末尾的节点。
 */
- (void)_trimToCost:(NSUInteger)costLimit {
    BOOL finish = NO;
    pthread_mutex_lock(&_lock);
    if (costLimit == 0) {
        [_lru removeAll];
        finish = YES;
    } else if (_lru->_totalCost <= costLimit) {
        finish = YES;
    }
    pthread_mutex_unlock(&_lock);
    if (finish) return;
    
    NSMutableArray *holder = [NSMutableArray new];
    while (!finish) {
        if (pthread_mutex_trylock(&_lock) == 0) {
            if (_lru->_totalCost > costLimit) {
                _YYLinkedMapNode *node = [_lru removeTailNode];//删除末尾节点
                if (node) [holder addObject:node];
            } else {
                finish = YES; //totalCost<=costLimit,检测完成
            }
            pthread_mutex_unlock(&_lock);
        } else {
            usleep(10 * 1000); //10 ms
        }
    }
    if (holder.count) {
        dispatch_queue_t queue = _lru->_releaseOnMainThread ? dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
        dispatch_async(queue, ^{
            [holder count]; // release in queue
        });
    }
}

//判断链表中的所有节点个数之和是否大于countLimit，如果超过，则从链表末尾开始删除节点，直到个数之和小于等于countLimit为止。
/**
 初始化时countLimit默认是NSUIntegerMax，如果不指定countLimit，节点的总个数永远不会超过这个限制，所以_trimToCount方法不会删除末尾节点。
 */
- (void)_trimToCount:(NSUInteger)countLimit {
    BOOL finish = NO;
    pthread_mutex_lock(&_lock);
    if (countLimit == 0) {
        [_lru removeAll];
        finish = YES;
    } else if (_lru->_totalCount <= countLimit) {
        finish = YES;
    }
    pthread_mutex_unlock(&_lock);
    if (finish) return;
    
    NSMutableArray *holder = [NSMutableArray new];
    while (!finish) {
        if (pthread_mutex_trylock(&_lock) == 0) {
            if (_lru->_totalCount > countLimit) {
                _YYLinkedMapNode *node = [_lru removeTailNode]; //删除末尾节点
                if (node) [holder addObject:node];
            } else {
                finish = YES; //totalCost<=costLimit,检测完成
            }
            pthread_mutex_unlock(&_lock);
        } else {
            usleep(10 * 1000); //10 ms
        }
    }
    if (holder.count) {
        dispatch_queue_t queue = _lru->_releaseOnMainThread ? dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
        dispatch_async(queue, ^{
            [holder count]; // release in queue
        });
    }
}
//遍历链表中的节点，删除那些和now时刻的时间间隔大于ageLimit的节点
/**
 由于链表中从头部至尾部的节点，访问时间由晚至早，所以尾部节点和now时刻的时间间隔较大，从尾节点开始删除。ageLimit的默认值是DBL_MAX，如果不人为指定ageLimit，则链表中节点不会被删除
 */
- (void)_trimToAge:(NSTimeInterval)ageLimit {
    BOOL finish = NO;
    NSTimeInterval now = CACurrentMediaTime();
    pthread_mutex_lock(&_lock);
    if (ageLimit <= 0) {
        [_lru removeAll];
        finish = YES;
    } else if (!_lru->_tail || (now - _lru->_tail->_time) <= ageLimit) {
        finish = YES;
    }
    pthread_mutex_unlock(&_lock);
    if (finish) return;
    
    NSMutableArray *holder = [NSMutableArray new];
    while (!finish) {
        if (pthread_mutex_trylock(&_lock) == 0) {
            if (_lru->_tail && (now - _lru->_tail->_time) > ageLimit) {
                _YYLinkedMapNode *node = [_lru removeTailNode];
                if (node) [holder addObject:node];
            } else {
                finish = YES;
            }
            pthread_mutex_unlock(&_lock);
        } else {
            usleep(10 * 1000); //10 ms
        }
    }
    if (holder.count) {
        dispatch_queue_t queue = _lru->_releaseOnMainThread ? dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
        dispatch_async(queue, ^{
            [holder count]; // release in queue
        });
    }
}

- (void)_appDidReceiveMemoryWarningNotification {
    if (self.didReceiveMemoryWarningBlock) {
        self.didReceiveMemoryWarningBlock(self);
    }
    if (self.shouldRemoveAllObjectsOnMemoryWarning) {
        [self removeAllObjects];
    }
}

- (void)_appDidEnterBackgroundNotification {
    if (self.didEnterBackgroundBlock) {
        self.didEnterBackgroundBlock(self);
    }
    if (self.shouldRemoveAllObjectsWhenEnteringBackground) {
        [self removeAllObjects];
    }
}

#pragma mark - public

- (instancetype)init {
    self = super.init;
    pthread_mutex_init(&_lock, NULL);
    _lru = [_YYLinkedMap new];
    _queue = dispatch_queue_create("com.ibireme.cache.memory", DISPATCH_QUEUE_SERIAL);
    
    _countLimit = NSUIntegerMax;
    _costLimit = NSUIntegerMax;
    _ageLimit = DBL_MAX;
    _autoTrimInterval = 5.0;
    _shouldRemoveAllObjectsOnMemoryWarning = YES;
    _shouldRemoveAllObjectsWhenEnteringBackground = YES;
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_appDidReceiveMemoryWarningNotification) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_appDidEnterBackgroundNotification) name:UIApplicationDidEnterBackgroundNotification object:nil];
    
    [self _trimRecursively];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
    [_lru removeAll];
    pthread_mutex_destroy(&_lock);
}

- (NSUInteger)totalCount {
    pthread_mutex_lock(&_lock);
    NSUInteger count = _lru->_totalCount;
    pthread_mutex_unlock(&_lock);
    return count;
}

- (NSUInteger)totalCost {
    pthread_mutex_lock(&_lock);
    NSUInteger totalCost = _lru->_totalCost;
    pthread_mutex_unlock(&_lock);
    return totalCost;
}

- (BOOL)releaseOnMainThread {
    pthread_mutex_lock(&_lock);
    BOOL releaseOnMainThread = _lru->_releaseOnMainThread;
    pthread_mutex_unlock(&_lock);
    return releaseOnMainThread;
}

- (void)setReleaseOnMainThread:(BOOL)releaseOnMainThread {
    pthread_mutex_lock(&_lock);
    _lru->_releaseOnMainThread = releaseOnMainThread;
    pthread_mutex_unlock(&_lock);
}

- (BOOL)releaseAsynchronously {
    pthread_mutex_lock(&_lock);
    BOOL releaseAsynchronously = _lru->_releaseAsynchronously;
    pthread_mutex_unlock(&_lock);
    return releaseAsynchronously;
}

- (void)setReleaseAsynchronously:(BOOL)releaseAsynchronously {
    pthread_mutex_lock(&_lock);
    _lru->_releaseAsynchronously = releaseAsynchronously;
    pthread_mutex_unlock(&_lock);
}

- (BOOL)containsObjectForKey:(id)key {
    if (!key) return NO;
    pthread_mutex_lock(&_lock);
    BOOL contains = CFDictionaryContainsKey(_lru->_dic, (__bridge const void *)(key));
    pthread_mutex_unlock(&_lock);
    return contains;
}
//调用objectForKey:方法访问缓存数据
/**
 该方法从字典中获取缓存数据，如果key对应的数据存在，则更新访问时间，根据最近最少使用原则，将本次操作的节点移动至链表的头部。如果不存在，则直接返回nil。
 */
- (id)objectForKey:(id)key {
    if (!key) return nil;
    pthread_mutex_lock(&_lock); //上锁
    _YYLinkedMapNode *node = CFDictionaryGetValue(_lru->_dic, (__bridge const void *)(key)); //从字典中取节点
    if (node) {
        node->_time = CACurrentMediaTime(); //更新节点访问时间
        [_lru bringNodeToHead:node]; //将节点移动至链表头部
    }
    pthread_mutex_unlock(&_lock); //解锁
    return node ? node->_value : nil;
}

- (void)setObject:(id)object forKey:(id)key {
    [self setObject:object forKey:key withCost:0];
}
//调用setObject: forKey:方法存储缓存数据
/**
 首先判断key和object是否为空，object如果为空，删除缓存中key对应的数据。
 然后从字典中查找key对应的缓存数据，分为两种情况，如果访问到节点，说明缓存数据存在，则根据最近最少使用原则，将本次操作的节点移动至链表的头部，同时更新节点的访问时间。
 如果访问不到节点，说明是第一次添加key和数据，需要创建一个新的节点，把节点存入字典中，并且加入链表头部。cost是指定的，默认是0。
 */
- (void)setObject:(id)object forKey:(id)key withCost:(NSUInteger)cost {
    if (!key) return;
    if (!object) {
        [self removeObjectForKey:key];
        return;
    }
    pthread_mutex_lock(&_lock); //上锁
    _YYLinkedMapNode *node = CFDictionaryGetValue(_lru->_dic, (__bridge const void *)(key)); //从字典中取节点
    NSTimeInterval now = CACurrentMediaTime();
    if (node) { //如果能取到，说明链表中之前存在key对应的缓存数据
        _lru->_totalCost -= node->_cost;
        _lru->_totalCost += cost;
        node->_cost = cost;
        node->_time = now; //更新节点的访问时间
        node->_value = object; //更新节点中存放的缓存数据
        [_lru bringNodeToHead:node]; //将节点移至链表头部
    } else {
        node = [_YYLinkedMapNode new];
        node->_cost = cost;
        node->_time = now; //设置节点的时间
        node->_key = key; //设置节点的key
        node->_value = object; //设置节点中存放的缓存数据
        [_lru insertNodeAtHead:node]; //将新的节点加入链表头部
    }
    if (_lru->_totalCost > _costLimit) {
        dispatch_async(_queue, ^{
            [self trimToCost:_costLimit];
        });
    }
    if (_lru->_totalCount > _countLimit) {
        _YYLinkedMapNode *node = [_lru removeTailNode];
        if (_lru->_releaseAsynchronously) {
            dispatch_queue_t queue = _lru->_releaseOnMainThread ? dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
            dispatch_async(queue, ^{
                [node class]; //hold and release in queue
            });
        } else if (_lru->_releaseOnMainThread && !pthread_main_np()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [node class]; //hold and release in queue
            });
        }
    }
    pthread_mutex_unlock(&_lock); //解锁
}

- (void)removeObjectForKey:(id)key {
    if (!key) return;
    pthread_mutex_lock(&_lock);
    _YYLinkedMapNode *node = CFDictionaryGetValue(_lru->_dic, (__bridge const void *)(key));
    if (node) {
        [_lru removeNode:node];
        if (_lru->_releaseAsynchronously) {
            dispatch_queue_t queue = _lru->_releaseOnMainThread ? dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
            dispatch_async(queue, ^{
                [node class]; //hold and release in queue
            });
        } else if (_lru->_releaseOnMainThread && !pthread_main_np()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [node class]; //hold and release in queue
            });
        }
    }
    pthread_mutex_unlock(&_lock);
}

- (void)removeAllObjects {
    pthread_mutex_lock(&_lock);
    [_lru removeAll];
    pthread_mutex_unlock(&_lock);
}

- (void)trimToCount:(NSUInteger)count {
    if (count == 0) {
        [self removeAllObjects];
        return;
    }
    [self _trimToCount:count];
}

- (void)trimToCost:(NSUInteger)cost {
    [self _trimToCost:cost];
}

- (void)trimToAge:(NSTimeInterval)age {
    [self _trimToAge:age];
}

- (NSString *)description {
    if (_name) return [NSString stringWithFormat:@"<%@: %p> (%@)", self.class, self, _name];
    else return [NSString stringWithFormat:@"<%@: %p>", self.class, self];
}

@end

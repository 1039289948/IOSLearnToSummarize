//
//  YYKVStorage.m
//  YYCache <https://github.com/ibireme/YYCache>
//
//  Created by ibireme on 15/4/22.
//  Copyright (c) 2015 ibireme.
//
//  This source code is licensed under the MIT-style license found in the
//  LICENSE file in the root directory of this source tree.
//

#import "YYKVStorage.h"
#import <UIKit/UIKit.h>
#import <time.h>

#if __has_include(<sqlite3.h>)
#import <sqlite3.h>
#else
#import "sqlite3.h"
#endif


static const NSUInteger kMaxErrorRetryCount = 8;
static const NSTimeInterval kMinRetryTimeInterval = 2.0;
static const int kPathLengthMax = PATH_MAX - 64;
static NSString *const kDBFileName = @"manifest.sqlite";
static NSString *const kDBShmFileName = @"manifest.sqlite-shm";
static NSString *const kDBWalFileName = @"manifest.sqlite-wal";
static NSString *const kDataDirectoryName = @"data";
static NSString *const kTrashDirectoryName = @"trash";


/*
 File:
 /path/
      /manifest.sqlite
      /manifest.sqlite-shm
      /manifest.sqlite-wal
      /data/
           /e10adc3949ba59abbe56e057f20f883e
           /e10adc3949ba59abbe56e057f20f883e
      /trash/
            /unused_file_or_folder
 
 SQL:
 create table if not exists manifest (
    key                 text,
    filename            text,
    size                integer,
    inline_data         blob,
    modification_time   integer,
    last_access_time    integer,
    extended_data       blob,
    primary key(key)
 ); 
 create index if not exists last_access_time_idx on manifest(last_access_time);
 */

/// Returns nil in App Extension.
static UIApplication *_YYSharedApplication() {
    static BOOL isAppExtension = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = NSClassFromString(@"UIApplication");
        if(!cls || ![cls respondsToSelector:@selector(sharedApplication)]) isAppExtension = YES;
        if ([[[NSBundle mainBundle] bundlePath] hasSuffix:@".appex"]) isAppExtension = YES;
    });
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
    return isAppExtension ? nil : [UIApplication performSelector:@selector(sharedApplication)];
#pragma clang diagnostic pop
}


@implementation YYKVStorageItem
@end

@implementation YYKVStorage {
    dispatch_queue_t _trashQueue;
    
    NSString *_path;
    NSString *_dbPath;
    NSString *_dataPath;
    NSString *_trashPath;
    
    sqlite3 *_db;
    CFMutableDictionaryRef _dbStmtCache;
    NSTimeInterval _dbLastOpenErrorTime;
    NSUInteger _dbOpenErrorCount;
}


#pragma mark - db

- (BOOL)_dbOpen {
    if (_db) return YES;
    
    int result = sqlite3_open(_dbPath.UTF8String, &_db);
    if (result == SQLITE_OK) {
        CFDictionaryKeyCallBacks keyCallbacks = kCFCopyStringDictionaryKeyCallBacks;
        CFDictionaryValueCallBacks valueCallbacks = {0};
        _dbStmtCache = CFDictionaryCreateMutable(CFAllocatorGetDefault(), 0, &keyCallbacks, &valueCallbacks);
        _dbLastOpenErrorTime = 0;
        _dbOpenErrorCount = 0;
        return YES;
    } else {
        _db = NULL;
        if (_dbStmtCache) CFRelease(_dbStmtCache);
        _dbStmtCache = NULL;
        _dbLastOpenErrorTime = CACurrentMediaTime();
        _dbOpenErrorCount++;
        
        if (_errorLogsEnabled) {
            NSLog(@"%s line:%d sqlite open failed (%d).", __FUNCTION__, __LINE__, result);
        }
        return NO;
    }
}

- (BOOL)_dbClose {
    if (!_db) return YES;
    
    int  result = 0;
    BOOL retry = NO;
    BOOL stmtFinalized = NO;
    
    if (_dbStmtCache) CFRelease(_dbStmtCache);
    _dbStmtCache = NULL;
    
    do {
        retry = NO;
        result = sqlite3_close(_db);
        if (result == SQLITE_BUSY || result == SQLITE_LOCKED) {
            if (!stmtFinalized) {
                stmtFinalized = YES;
                sqlite3_stmt *stmt;
                while ((stmt = sqlite3_next_stmt(_db, nil)) != 0) {
                    sqlite3_finalize(stmt);
                    retry = YES;
                }
            }
        } else if (result != SQLITE_OK) {
            if (_errorLogsEnabled) {
                NSLog(@"%s line:%d sqlite close failed (%d).", __FUNCTION__, __LINE__, result);
            }
        }
    } while (retry);
    _db = NULL;
    return YES;
}

- (BOOL)_dbCheck {
    if (!_db) {
        if (_dbOpenErrorCount < kMaxErrorRetryCount &&
            CACurrentMediaTime() - _dbLastOpenErrorTime > kMinRetryTimeInterval) {
            return [self _dbOpen] && [self _dbInitialize];
        } else {
            return NO;
        }
    }
    return YES;
}

//_dbInitialize方法调用sql语句在数据库中创建一张表
/**
 "pragma journal_mode = wal"表示使用WAL模式进行数据库操作，如果不指定，默认DELETE模式 是"journal_mode=DELETE"。
 使用WAL模式时，改写操作数据库的操作会先写入WAL文件，而暂时不改动数据库文件，当执行checkPoint方法时，WAL文件的内容被批量写入数据库。
 checkPoint操作会自动执行，也可以改为手动。
 WAL模式的优点是支持读写并发，性能更高，但是当wal文件很大时，需要调用checkPoint方法清空wal文件中的内容
 */
- (BOOL)_dbInitialize {
    NSString *sql = @"pragma journal_mode = wal; pragma synchronous = normal; create table if not exists manifest (key text, filename text, size integer, inline_data blob, modification_time integer, last_access_time integer, extended_data blob, primary key(key)); create index if not exists last_access_time_idx on manifest(last_access_time);";
    return [self _dbExecute:sql];
}

- (void)_dbCheckpoint {
    if (![self _dbCheck]) return;
    // Cause a checkpoint to occur, merge `sqlite-wal` file to `sqlite` file.
    sqlite3_wal_checkpoint(_db, NULL);
}

- (BOOL)_dbExecute:(NSString *)sql {
    if (sql.length == 0) return NO;
    if (![self _dbCheck]) return NO;
    
    char *error = NULL;
    int result = sqlite3_exec(_db, sql.UTF8String, NULL, NULL, &error);
    if (error) {
        if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite exec error (%d): %s", __FUNCTION__, __LINE__, result, error);
        sqlite3_free(error);
    }
    
    return result == SQLITE_OK;
}

- (sqlite3_stmt *)_dbPrepareStmt:(NSString *)sql {
    if (![self _dbCheck] || sql.length == 0 || !_dbStmtCache) return NULL;
    sqlite3_stmt *stmt = (sqlite3_stmt *)CFDictionaryGetValue(_dbStmtCache, (__bridge const void *)(sql));
    if (!stmt) {
        int result = sqlite3_prepare_v2(_db, sql.UTF8String, -1, &stmt, NULL);
        if (result != SQLITE_OK) {
            if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite stmt prepare error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
            return NULL;
        }
        CFDictionarySetValue(_dbStmtCache, (__bridge const void *)(sql), stmt);
    } else {
        sqlite3_reset(stmt);
    }
    return stmt;
}

- (NSString *)_dbJoinedKeys:(NSArray *)keys {
    NSMutableString *string = [NSMutableString new];
    for (NSUInteger i = 0,max = keys.count; i < max; i++) {
        [string appendString:@"?"];
        if (i + 1 != max) {
            [string appendString:@","];
        }
    }
    return string;
}

- (void)_dbBindJoinedKeys:(NSArray *)keys stmt:(sqlite3_stmt *)stmt fromIndex:(int)index{
    for (int i = 0, max = (int)keys.count; i < max; i++) {
        NSString *key = keys[i];
        sqlite3_bind_text(stmt, index + i, key.UTF8String, -1, NULL);
    }
}

/**
 该方法首先判断fileName即文件名是否为空，如果存在，则调用_fileWriteWithName方法将缓存的数据写入文件系统中，同时将数据写入数据库，需要注意的是，调用_dbSaveWithKey:value:fileName:extendedData:方法会创建一条SQL记录写入表中，
 
 该方法首先创建sql语句，value括号中的参数"?"表示参数需要通过变量绑定，"?"后面的数字表示绑定变量对应的索引号，如果VALUES (?1, ?1, ?2)，则可以用同一个值绑定多个变量。
 
 然后调用_dbPrepareStmt方法构建数据位置指针stmt，标记查询到的数据位置，sqlite3_prepare_v2()方法进行数据库操作的准备工作，第一个参数为成功打开的数据库指针db，第二个参数为要执行的sql语句，第三个参数为stmt指针的地址，这个方法也会返回一个int值，作为标记状态是否成功。
 
 接着调用sqlite3_bind_text()方法将实际值作为变量绑定sql中的"?"参数，序号对应"?"后面对应的数字。不同类型的变量调用不同的方法，例如二进制数据是sqlite3_bind_blob方法。
 
 同时判断如果fileName存在，则生成的sql语句只绑定数据的相关描述，不绑定inline_data，即实际存储的二进制数据，因为该缓存之前已经将二进制数据写进文件。这样做可以防止缓存数据同时写入文件和数据库，造成缓存空间的浪费。如果fileName不存在，则只写入数据库中，这时sql语句绑定inline_data，不绑定fileName。
 
 最后执行sqlite3_step方法执行sql语句，对stmt指针进行移动，并返回一个int值。
 */
- (BOOL)_dbSaveWithKey:(NSString *)key value:(NSData *)value fileName:(NSString *)fileName extendedData:(NSData *)extendedData {
    //构建sql语句，将一条记录添加进manifest表
    NSString *sql = @"insert or replace into manifest (key, filename, size, inline_data, modification_time, last_access_time, extended_data) values (?1, ?2, ?3, ?4, ?5, ?6, ?7);";
    sqlite3_stmt *stmt = [self _dbPrepareStmt:sql]; //准备sql语句，返回stmt指针
    if (!stmt) return NO;
    
    int timestamp = (int)time(NULL);
    sqlite3_bind_text(stmt, 1, key.UTF8String, -1, NULL); //绑定参数值对应"?1"
    sqlite3_bind_text(stmt, 2, fileName.UTF8String, -1, NULL); //绑定参数值对应"?2"
    sqlite3_bind_int(stmt, 3, (int)value.length); //绑定参数值对应"?3"
    if (fileName.length == 0) {
        sqlite3_bind_blob(stmt, 4, value.bytes, (int)value.length, 0); //如果fileName不存在，绑定参数值value.bytes对应"?4"
    } else {
        sqlite3_bind_blob(stmt, 4, NULL, 0, 0); //如果fileName存在，不绑定，"?4"对应的参数值为null
    }
    sqlite3_bind_int(stmt, 5, timestamp); //绑定参数值对应"?5"
    sqlite3_bind_int(stmt, 6, timestamp); //绑定参数值对应"?6"
    sqlite3_bind_blob(stmt, 7, extendedData.bytes, (int)extendedData.length, 0); //绑定参数值对应"?7"
    
    int result = sqlite3_step(stmt); //开始执行sql语句
    if (result != SQLITE_DONE) {
        if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite insert error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        return NO;
    }
    return YES;
}

- (BOOL)_dbUpdateAccessTimeWithKey:(NSString *)key {
    NSString *sql = @"update manifest set last_access_time = ?1 where key = ?2;";
    sqlite3_stmt *stmt = [self _dbPrepareStmt:sql];
    if (!stmt) return NO;
    sqlite3_bind_int(stmt, 1, (int)time(NULL));
    sqlite3_bind_text(stmt, 2, key.UTF8String, -1, NULL);
    int result = sqlite3_step(stmt);
    if (result != SQLITE_DONE) {
        if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite update error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        return NO;
    }
    return YES;
}

- (BOOL)_dbUpdateAccessTimeWithKeys:(NSArray *)keys {
    if (![self _dbCheck]) return NO;
    int t = (int)time(NULL);
     NSString *sql = [NSString stringWithFormat:@"update manifest set last_access_time = %d where key in (%@);", t, [self _dbJoinedKeys:keys]];
    
    sqlite3_stmt *stmt = NULL;
    int result = sqlite3_prepare_v2(_db, sql.UTF8String, -1, &stmt, NULL);
    if (result != SQLITE_OK) {
        if (_errorLogsEnabled)  NSLog(@"%s line:%d sqlite stmt prepare error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        return NO;
    }
    
    [self _dbBindJoinedKeys:keys stmt:stmt fromIndex:1];
    result = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    if (result != SQLITE_DONE) {
        if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite update error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        return NO;
    }
    return YES;
}
/**
 该方法删除指定key对应的缓存数据，区分type，如果是YYKVStorageTypeSQLite，调用_dbDeleteItemWithKey:从数据库中删除对应key的缓存记录
 
 如果是YYKVStorageTypeFile或者YYKVStorageTypeMixed，说明可能缓存数据之前可能被写入文件中，判断方法是调用_dbGetFilenameWithKey:方法从数据库中查找key对应的SQL记录的fileName字段。
 该方法的流程和上面的方法差不多，只是sql语句换成了select查询语句。如果查询到fileName，说明数据之前写入过文件中，调用_fileDeleteWithName方法删除数据，同时删除数据库中的记录。否则只从数据库中删除SQL记录。
 */
- (BOOL)_dbDeleteItemWithKey:(NSString *)key {
    NSString *sql = @"delete from manifest where key = ?1;"; //sql语句
    sqlite3_stmt *stmt = [self _dbPrepareStmt:sql]; //准备sql语句，返回stmt指针
    if (!stmt) return NO;
    sqlite3_bind_text(stmt, 1, key.UTF8String, -1, NULL); //绑定参数
    
    int result = sqlite3_step(stmt); //执行sql语句
    if (result != SQLITE_DONE) {
        if (_errorLogsEnabled) NSLog(@"%s line:%d db delete error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        return NO;
    }
    return YES;
}

- (BOOL)_dbDeleteItemWithKeys:(NSArray *)keys {
    if (![self _dbCheck]) return NO;
    NSString *sql =  [NSString stringWithFormat:@"delete from manifest where key in (%@);", [self _dbJoinedKeys:keys]];
    sqlite3_stmt *stmt = NULL;
    int result = sqlite3_prepare_v2(_db, sql.UTF8String, -1, &stmt, NULL);
    if (result != SQLITE_OK) {
        if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite stmt prepare error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        return NO;
    }
    
    [self _dbBindJoinedKeys:keys stmt:stmt fromIndex:1];
    result = sqlite3_step(stmt);  //执行参数
    sqlite3_finalize(stmt); //对stmt指针进行关闭
    if (result == SQLITE_ERROR) {
        if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite delete error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        return NO;
    }
    return YES;
}

- (BOOL)_dbDeleteItemsWithSizeLargerThan:(int)size {
    NSString *sql = @"delete from manifest where size > ?1;";
    sqlite3_stmt *stmt = [self _dbPrepareStmt:sql];
    if (!stmt) return NO;
    sqlite3_bind_int(stmt, 1, size);
    int result = sqlite3_step(stmt);
    if (result != SQLITE_DONE) {
        if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite delete error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        return NO;
    }
    return YES;
}

- (BOOL)_dbDeleteItemsWithTimeEarlierThan:(int)time {
    NSString *sql = @"delete from manifest where last_access_time < ?1;";
    sqlite3_stmt *stmt = [self _dbPrepareStmt:sql];
    if (!stmt) return NO;
    sqlite3_bind_int(stmt, 1, time);
    int result = sqlite3_step(stmt);
    if (result != SQLITE_DONE) {
        if (_errorLogsEnabled)  NSLog(@"%s line:%d sqlite delete error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        return NO;
    }
    return YES;
}

- (YYKVStorageItem *)_dbGetItemFromStmt:(sqlite3_stmt *)stmt excludeInlineData:(BOOL)excludeInlineData {
    int i = 0;
    char *key = (char *)sqlite3_column_text(stmt, i++); //key
    char *filename = (char *)sqlite3_column_text(stmt, i++); //filename
    int size = sqlite3_column_int(stmt, i++); //数据大小
    const void *inline_data = excludeInlineData ? NULL : sqlite3_column_blob(stmt, i); //二进制数据
    int inline_data_bytes = excludeInlineData ? 0 : sqlite3_column_bytes(stmt, i++);
    int modification_time = sqlite3_column_int(stmt, i++); //修改时间
    int last_access_time = sqlite3_column_int(stmt, i++); //访问时间
    const void *extended_data = sqlite3_column_blob(stmt, i);//附加数据
    int extended_data_bytes = sqlite3_column_bytes(stmt, i++);
    
     //用YYKVStorageItem对象封装
    YYKVStorageItem *item = [YYKVStorageItem new];
    if (key) item.key = [NSString stringWithUTF8String:key];
    if (filename && *filename != 0) item.filename = [NSString stringWithUTF8String:filename];
    item.size = size;
    if (inline_data_bytes > 0 && inline_data) item.value = [NSData dataWithBytes:inline_data length:inline_data_bytes];
    item.modTime = modification_time;
    item.accessTime = last_access_time;
    if (extended_data_bytes > 0 && extended_data) item.extendedData = [NSData dataWithBytes:extended_data length:extended_data_bytes];
    return item;
}

/**
 sql语句是查询符合key值的记录中的各个字段，例如缓存的key、大小、二进制数据、访问时间等信息，
    excludeInlineData表示查询数据时，是否要排除inline_data字段，即是否查询二进制数据，执行sql语句后，
    通过stmt指针和_dbGetItemFromStmt:excludeInlineData:方法取出各个字段，
    并创建YYKVStorageItem对象，将记录的各个字段赋值给各个属性
 */
- (YYKVStorageItem *)_dbGetItemWithKey:(NSString *)key excludeInlineData:(BOOL)excludeInlineData {
    //查询sql语句，是否排除inline_data
    NSString *sql = excludeInlineData ? @"select key, filename, size, modification_time, last_access_time, extended_data from manifest where key = ?1;" : @"select key, filename, size, inline_data, modification_time, last_access_time, extended_data from manifest where key = ?1;";
    sqlite3_stmt *stmt = [self _dbPrepareStmt:sql]; //准备工作，构建stmt
    if (!stmt) return nil;
    sqlite3_bind_text(stmt, 1, key.UTF8String, -1, NULL); //绑定参数
    
    YYKVStorageItem *item = nil;
    int result = sqlite3_step(stmt); //执行sql语句
    if (result == SQLITE_ROW) {
        item = [self _dbGetItemFromStmt:stmt excludeInlineData:excludeInlineData]; //取出查询记录中的各个字段，用YYKVStorageItem封装并返回
    } else {
        if (result != SQLITE_DONE) {
            if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite query error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        }
    }
    return item;
}

- (NSMutableArray *)_dbGetItemWithKeys:(NSArray *)keys excludeInlineData:(BOOL)excludeInlineData {
    if (![self _dbCheck]) return nil;
    NSString *sql;
    if (excludeInlineData) {
        sql = [NSString stringWithFormat:@"select key, filename, size, modification_time, last_access_time, extended_data from manifest where key in (%@);", [self _dbJoinedKeys:keys]];
    } else {
        sql = [NSString stringWithFormat:@"select key, filename, size, inline_data, modification_time, last_access_time, extended_data from manifest where key in (%@)", [self _dbJoinedKeys:keys]];
    }
    
    sqlite3_stmt *stmt = NULL;
    int result = sqlite3_prepare_v2(_db, sql.UTF8String, -1, &stmt, NULL);
    if (result != SQLITE_OK) {
        if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite stmt prepare error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        return nil;
    }
    
    [self _dbBindJoinedKeys:keys stmt:stmt fromIndex:1];
    NSMutableArray *items = [NSMutableArray new];
    do {
        result = sqlite3_step(stmt);
        if (result == SQLITE_ROW) {
            YYKVStorageItem *item = [self _dbGetItemFromStmt:stmt excludeInlineData:excludeInlineData];
            if (item) [items addObject:item];
        } else if (result == SQLITE_DONE) {
            break;
        } else {
            if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite query error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
            items = nil;
            break;
        }
    } while (1);
    sqlite3_finalize(stmt);
    return items;
}

- (NSData *)_dbGetValueWithKey:(NSString *)key {
    NSString *sql = @"select inline_data from manifest where key = ?1;";
    sqlite3_stmt *stmt = [self _dbPrepareStmt:sql];
    if (!stmt) return nil;
    sqlite3_bind_text(stmt, 1, key.UTF8String, -1, NULL);
    
    int result = sqlite3_step(stmt);
    if (result == SQLITE_ROW) {
        const void *inline_data = sqlite3_column_blob(stmt, 0);
        int inline_data_bytes = sqlite3_column_bytes(stmt, 0);
        if (!inline_data || inline_data_bytes <= 0) return nil;
        return [NSData dataWithBytes:inline_data length:inline_data_bytes];
    } else {
        if (result != SQLITE_DONE) {
            if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite query error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        }
        return nil;
    }
}
//从数据库中查找key对应的SQL记录的fileName字段。该方法的流程和上面的方法差不多，只是sql语句换成了select查询语句。如果查询到fileName，说明数据之前写入过文件中
- (NSString *)_dbGetFilenameWithKey:(NSString *)key {
    NSString *sql = @"select filename from manifest where key = ?1;";
    sqlite3_stmt *stmt = [self _dbPrepareStmt:sql];
    if (!stmt) return nil;
    sqlite3_bind_text(stmt, 1, key.UTF8String, -1, NULL);
    int result = sqlite3_step(stmt);
    if (result == SQLITE_ROW) {
        char *filename = (char *)sqlite3_column_text(stmt, 0);
        if (filename && *filename != 0) {
            return [NSString stringWithUTF8String:filename];
        }
    } else {
        if (result != SQLITE_DONE) {
            if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite query error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        }
    }
    return nil;
}

- (NSMutableArray *)_dbGetFilenameWithKeys:(NSArray *)keys {
    if (![self _dbCheck]) return nil;
    NSString *sql = [NSString stringWithFormat:@"select filename from manifest where key in (%@);", [self _dbJoinedKeys:keys]];
    sqlite3_stmt *stmt = NULL;
    int result = sqlite3_prepare_v2(_db, sql.UTF8String, -1, &stmt, NULL);
    if (result != SQLITE_OK) {
        if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite stmt prepare error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        return nil;
    }
    
    [self _dbBindJoinedKeys:keys stmt:stmt fromIndex:1];
    NSMutableArray *filenames = [NSMutableArray new];
    do {
        result = sqlite3_step(stmt);
        if (result == SQLITE_ROW) {
            char *filename = (char *)sqlite3_column_text(stmt, 0);
            if (filename && *filename != 0) {
                NSString *name = [NSString stringWithUTF8String:filename];
                if (name) [filenames addObject:name];
            }
        } else if (result == SQLITE_DONE) {
            break;
        } else {
            if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite query error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
            filenames = nil;
            break;
        }
    } while (1);
    sqlite3_finalize(stmt);
    return filenames;
}

- (NSMutableArray *)_dbGetFilenamesWithSizeLargerThan:(int)size {
    NSString *sql = @"select filename from manifest where size > ?1 and filename is not null;";
    sqlite3_stmt *stmt = [self _dbPrepareStmt:sql];
    if (!stmt) return nil;
    sqlite3_bind_int(stmt, 1, size);
    
    NSMutableArray *filenames = [NSMutableArray new];
    do {
        int result = sqlite3_step(stmt);
        if (result == SQLITE_ROW) {
            char *filename = (char *)sqlite3_column_text(stmt, 0);
            if (filename && *filename != 0) {
                NSString *name = [NSString stringWithUTF8String:filename];
                if (name) [filenames addObject:name];
            }
        } else if (result == SQLITE_DONE) {
            break;
        } else {
            if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite query error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
            filenames = nil;
            break;
        }
    } while (1);
    return filenames;
}

- (NSMutableArray *)_dbGetFilenamesWithTimeEarlierThan:(int)time {
    NSString *sql = @"select filename from manifest where last_access_time < ?1 and filename is not null;";
    sqlite3_stmt *stmt = [self _dbPrepareStmt:sql];
    if (!stmt) return nil;
    sqlite3_bind_int(stmt, 1, time);
    
    NSMutableArray *filenames = [NSMutableArray new];
    do {
        int result = sqlite3_step(stmt);
        if (result == SQLITE_ROW) {
            char *filename = (char *)sqlite3_column_text(stmt, 0);
            if (filename && *filename != 0) {
                NSString *name = [NSString stringWithUTF8String:filename];
                if (name) [filenames addObject:name];
            }
        } else if (result == SQLITE_DONE) {
            break;
        } else {
            if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite query error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
            filenames = nil;
            break;
        }
    } while (1);
    return filenames;
}

- (NSMutableArray *)_dbGetItemSizeInfoOrderByTimeAscWithLimit:(int)count {
    NSString *sql = @"select key, filename, size from manifest order by last_access_time asc limit ?1;";
    sqlite3_stmt *stmt = [self _dbPrepareStmt:sql];
    if (!stmt) return nil;
    sqlite3_bind_int(stmt, 1, count);
    
    NSMutableArray *items = [NSMutableArray new];
    do {
        int result = sqlite3_step(stmt);
        if (result == SQLITE_ROW) {
            char *key = (char *)sqlite3_column_text(stmt, 0);
            char *filename = (char *)sqlite3_column_text(stmt, 1);
            int size = sqlite3_column_int(stmt, 2);
            NSString *keyStr = key ? [NSString stringWithUTF8String:key] : nil;
            if (keyStr) {
                YYKVStorageItem *item = [YYKVStorageItem new];
                item.key = key ? [NSString stringWithUTF8String:key] : nil;
                item.filename = filename ? [NSString stringWithUTF8String:filename] : nil;
                item.size = size;
                [items addObject:item];
            }
        } else if (result == SQLITE_DONE) {
            break;
        } else {
            if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite query error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
            items = nil;
            break;
        }
    } while (1);
    return items;
}

- (int)_dbGetItemCountWithKey:(NSString *)key {
    NSString *sql = @"select count(key) from manifest where key = ?1;";
    sqlite3_stmt *stmt = [self _dbPrepareStmt:sql];
    if (!stmt) return -1;
    sqlite3_bind_text(stmt, 1, key.UTF8String, -1, NULL);
    int result = sqlite3_step(stmt);
    if (result != SQLITE_ROW) {
        if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite query error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        return -1;
    }
    return sqlite3_column_int(stmt, 0);
}

- (int)_dbGetTotalItemSize {
    NSString *sql = @"select sum(size) from manifest;";
    sqlite3_stmt *stmt = [self _dbPrepareStmt:sql];
    if (!stmt) return -1;
    int result = sqlite3_step(stmt);
    if (result != SQLITE_ROW) {
        if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite query error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        return -1;
    }
    return sqlite3_column_int(stmt, 0);
}

- (int)_dbGetTotalItemCount {
    NSString *sql = @"select count(*) from manifest;";
    sqlite3_stmt *stmt = [self _dbPrepareStmt:sql];
    if (!stmt) return -1;
    int result = sqlite3_step(stmt);
    if (result != SQLITE_ROW) {
        if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite query error (%d): %s", __FUNCTION__, __LINE__, result, sqlite3_errmsg(_db));
        return -1;
    }
    return sqlite3_column_int(stmt, 0);
}


#pragma mark - file

- (BOOL)_fileWriteWithName:(NSString *)filename data:(NSData *)data {
    NSString *path = [_dataPath stringByAppendingPathComponent:filename];
    return [data writeToFile:path atomically:NO];
}

- (NSData *)_fileReadWithName:(NSString *)filename {
    NSString *path = [_dataPath stringByAppendingPathComponent:filename];
    NSData *data = [NSData dataWithContentsOfFile:path];
    return data;
}

- (BOOL)_fileDeleteWithName:(NSString *)filename {
    NSString *path = [_dataPath stringByAppendingPathComponent:filename];
    return [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

- (BOOL)_fileMoveAllToTrash {
    CFUUIDRef uuidRef = CFUUIDCreate(NULL);
    CFStringRef uuid = CFUUIDCreateString(NULL, uuidRef);
    CFRelease(uuidRef);
    NSString *tmpPath = [_trashPath stringByAppendingPathComponent:(__bridge NSString *)(uuid)];
    BOOL suc = [[NSFileManager defaultManager] moveItemAtPath:_dataPath toPath:tmpPath error:nil];
    if (suc) {
        suc = [[NSFileManager defaultManager] createDirectoryAtPath:_dataPath withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    CFRelease(uuid);
    return suc;
}

- (void)_fileEmptyTrashInBackground {
    NSString *trashPath = _trashPath;
    dispatch_queue_t queue = _trashQueue;
    dispatch_async(queue, ^{
        NSFileManager *manager = [NSFileManager new];
        NSArray *directoryContents = [manager contentsOfDirectoryAtPath:trashPath error:NULL];
        for (NSString *path in directoryContents) {
            NSString *fullPath = [trashPath stringByAppendingPathComponent:path];
            [manager removeItemAtPath:fullPath error:NULL];
        }
    });
}


#pragma mark - private

/**
 Delete all files and empty in background.
 Make sure the db is closed.
 */
- (void)_reset {
    [[NSFileManager defaultManager] removeItemAtPath:[_path stringByAppendingPathComponent:kDBFileName] error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:[_path stringByAppendingPathComponent:kDBShmFileName] error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:[_path stringByAppendingPathComponent:kDBWalFileName] error:nil];
    [self _fileMoveAllToTrash];
    [self _fileEmptyTrashInBackground];
}

#pragma mark - public

- (instancetype)init {
    @throw [NSException exceptionWithName:@"YYKVStorage init error" reason:@"Please use the designated initializer and pass the 'path' and 'type'." userInfo:nil];
    return [self initWithPath:@"" type:YYKVStorageTypeFile];
}

//调用initWithPath: type:方法进行初始化，指定了存储方式，创建了缓存文件夹和SQLite数据库用于存放缓存，打开并初始化数据库
/**
 dataPath和trashPath用于文件的方式读写缓存数据，当dataPath中的部分缓存数据需要被清除时，先将其移至trashPath中，然后统一清空trashPath中的数据，类似回收站的思路。
 _dbPath是数据库文件，需要创建并初始化
 */
- (instancetype)initWithPath:(NSString *)path type:(YYKVStorageType)type {
    if (path.length == 0 || path.length > kPathLengthMax) {
        NSLog(@"YYKVStorage init error: invalid path: [%@].", path);
        return nil;
    }
    if (type > YYKVStorageTypeMixed) {
        NSLog(@"YYKVStorage init error: invalid type: %lu.", (unsigned long)type);
        return nil;
    }
    
    self = [super init];
    _path = path.copy;
    _type = type; //指定存储方式，是数据库还是文件存储
    _dataPath = [path stringByAppendingPathComponent:kDataDirectoryName]; //缓存数据的文件路径
    _trashPath = [path stringByAppendingPathComponent:kTrashDirectoryName]; //存放垃圾缓存数据的文件路径
    _trashQueue = dispatch_queue_create("com.ibireme.cache.disk.trash", DISPATCH_QUEUE_SERIAL);
    _dbPath = [path stringByAppendingPathComponent:kDBFileName]; //数据库路径
    _errorLogsEnabled = YES;
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:path
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&error] ||
        ![[NSFileManager defaultManager] createDirectoryAtPath:[path stringByAppendingPathComponent:kDataDirectoryName]
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&error] ||
        ![[NSFileManager defaultManager] createDirectoryAtPath:[path stringByAppendingPathComponent:kTrashDirectoryName]
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&error]) {
        NSLog(@"YYKVStorage init error:%@", error);
        return nil;
    }
    //创建并打开数据库、在数据库中建表
    if (![self _dbOpen] || ![self _dbInitialize]) {
        // db file may broken...
        [self _dbClose];
        [self _reset]; // rebuild
        if (![self _dbOpen] || ![self _dbInitialize]) {
            [self _dbClose];
            NSLog(@"YYKVStorage init error: fail to open sqlite db.");
            return nil;
        }
    }
    [self _fileEmptyTrashInBackground]; // empty the trash if failed at last time
    return self;
}

- (void)dealloc {
    UIBackgroundTaskIdentifier taskID = [_YYSharedApplication() beginBackgroundTaskWithExpirationHandler:^{}];
    [self _dbClose];
    if (taskID != UIBackgroundTaskInvalid) {
        [_YYSharedApplication() endBackgroundTask:taskID];
    }
}

- (BOOL)saveItem:(YYKVStorageItem *)item {
    return [self saveItemWithKey:item.key value:item.value filename:item.filename extendedData:item.extendedData];
}

- (BOOL)saveItemWithKey:(NSString *)key value:(NSData *)value {
    return [self saveItemWithKey:key value:value filename:nil extendedData:nil];
}

//写入缓存数据
/**
 该方法首先判断fileName即文件名是否为空，如果存在，则调用_fileWriteWithName方法将缓存的数据写入文件系统中，同时将数据写入数据库，需要注意的是，调用_dbSaveWithKey:value:fileName:extendedData:方法会创建一条SQL记录写入表中，
 
 */
- (BOOL)saveItemWithKey:(NSString *)key value:(NSData *)value filename:(NSString *)filename extendedData:(NSData *)extendedData {
    if (key.length == 0 || value.length == 0) return NO;
    if (_type == YYKVStorageTypeFile && filename.length == 0) {
        return NO;
    }
    //如果有文件名，说明需要写入文件中
    if (filename.length) {
        if (![self _fileWriteWithName:filename data:value]) {//写数据进文件
            return NO;
        }
        //写文件进数据库
        if (![self _dbSaveWithKey:key value:value fileName:filename extendedData:extendedData]) {
            [self _fileDeleteWithName:filename]; //写失败，同时删除文件中的数据
            return NO;
        }
        return YES;
    } else {
        if (_type != YYKVStorageTypeSQLite) {
            NSString *filename = [self _dbGetFilenameWithKey:key];
            if (filename) {
                [self _fileDeleteWithName:filename]; //从文件中删除缓存
            }
        }
        //写入数据库
        return [self _dbSaveWithKey:key value:value fileName:nil extendedData:extendedData];
    }
}
/**
 如果是YYKVStorageTypeFile或者YYKVStorageTypeMixed，说明可能缓存数据之前可能被写入文件中，判断方法是调用_dbGetFilenameWithKey:方法从数据库中查找key对应的SQL记录的fileName字段。
 该方法的流程和上面的方法差不多，只是sql语句换成了select查询语句。如果查询到fileName，说明数据之前写入过文件中，调用_fileDeleteWithName方法删除数据，同时删除数据库中的记录。否则只从数据库中删除SQL记录。
 */
- (BOOL)removeItemForKey:(NSString *)key {
    if (key.length == 0) return NO;
    switch (_type) {
        case YYKVStorageTypeSQLite: {
            return [self _dbDeleteItemWithKey:key];
        } break;
        case YYKVStorageTypeFile:
        case YYKVStorageTypeMixed: {
            NSString *filename = [self _dbGetFilenameWithKey:key];
            if (filename) {
                [self _fileDeleteWithName:filename];
            }
            return [self _dbDeleteItemWithKey:key];
        } break;
        default: return NO;
    }
}

- (BOOL)removeItemForKeys:(NSArray *)keys {
    if (keys.count == 0) return NO;
    switch (_type) {
        case YYKVStorageTypeSQLite: {
            return [self _dbDeleteItemWithKeys:keys];
        } break;
        case YYKVStorageTypeFile:
        case YYKVStorageTypeMixed: {
            NSArray *filenames = [self _dbGetFilenameWithKeys:keys];
            for (NSString *filename in filenames) {
                [self _fileDeleteWithName:filename];
            }
            return [self _dbDeleteItemWithKeys:keys];
        } break;
        default: return NO;
    }
}
/**
 方法删除那些size大于指定size的缓存数据。同样是区分type，删除的逻辑也和上面的方法一致。
 _dbDeleteItemsWithSizeLargerThan方法除了sql语句不同，操作数据库的步骤相同。
 _dbCheckpoint方法调用sqlite3_wal_checkpoint方法进行checkpoint操作，将数据同步到数据库中。
 调用_dbGetFilenameWithKey:方法从数据库中查找key对应的SQL记录的fileName字段。
 */
- (BOOL)removeItemsLargerThanSize:(int)size {
    if (size == INT_MAX) return YES;
    if (size <= 0) return [self removeAllItems];
    
    switch (_type) {
        case YYKVStorageTypeSQLite: {
            if ([self _dbDeleteItemsWithSizeLargerThan:size]) {
                [self _dbCheckpoint];
                return YES;
            }
        } break;
        case YYKVStorageTypeFile:
        case YYKVStorageTypeMixed: {
            NSArray *filenames = [self _dbGetFilenamesWithSizeLargerThan:size];
            for (NSString *name in filenames) {
                [self _fileDeleteWithName:name];
            }
            if ([self _dbDeleteItemsWithSizeLargerThan:size]) {
                [self _dbCheckpoint];
                return YES;
            }
        } break;
    }
    return NO;
}

- (BOOL)removeItemsEarlierThanTime:(int)time {
    if (time <= 0) return YES;
    if (time == INT_MAX) return [self removeAllItems];
    
    switch (_type) {
        case YYKVStorageTypeSQLite: {
            if ([self _dbDeleteItemsWithTimeEarlierThan:time]) {
                [self _dbCheckpoint];
                return YES;
            }
        } break;
        case YYKVStorageTypeFile:
        case YYKVStorageTypeMixed: {
            NSArray *filenames = [self _dbGetFilenamesWithTimeEarlierThan:time];
            for (NSString *name in filenames) {
                [self _fileDeleteWithName:name];
            }
            if ([self _dbDeleteItemsWithTimeEarlierThan:time]) {
                [self _dbCheckpoint];
                return YES;
            }
        } break;
    }
    return NO;
}

- (BOOL)removeItemsToFitSize:(int)maxSize {
    if (maxSize == INT_MAX) return YES;
    if (maxSize <= 0) return [self removeAllItems];
    
    int total = [self _dbGetTotalItemSize];
    if (total < 0) return NO;
    if (total <= maxSize) return YES;
    
    NSArray *items = nil;
    BOOL suc = NO;
    do {
        int perCount = 16;
        items = [self _dbGetItemSizeInfoOrderByTimeAscWithLimit:perCount];
        for (YYKVStorageItem *item in items) {
            if (total > maxSize) {
                if (item.filename) {
                    [self _fileDeleteWithName:item.filename];
                }
                suc = [self _dbDeleteItemWithKey:item.key];
                total -= item.size;
            } else {
                break;
            }
            if (!suc) break;
        }
    } while (total > maxSize && items.count > 0 && suc);
    if (suc) [self _dbCheckpoint];
    return suc;
}

- (BOOL)removeItemsToFitCount:(int)maxCount {
    if (maxCount == INT_MAX) return YES;
    if (maxCount <= 0) return [self removeAllItems];
    
    int total = [self _dbGetTotalItemCount];
    if (total < 0) return NO;
    if (total <= maxCount) return YES;
    
    NSArray *items = nil;
    BOOL suc = NO;
    do {
        int perCount = 16;
        items = [self _dbGetItemSizeInfoOrderByTimeAscWithLimit:perCount];
        for (YYKVStorageItem *item in items) {
            if (total > maxCount) {
                if (item.filename) {
                    [self _fileDeleteWithName:item.filename];
                }
                suc = [self _dbDeleteItemWithKey:item.key];
                total--;
            } else {
                break;
            }
            if (!suc) break;
        }
    } while (total > maxCount && items.count > 0 && suc);
    if (suc) [self _dbCheckpoint];
    return suc;
}

- (BOOL)removeAllItems {
    if (![self _dbClose]) return NO;
    [self _reset];
    if (![self _dbOpen]) return NO;
    if (![self _dbInitialize]) return NO;
    return YES;
}

- (void)removeAllItemsWithProgressBlock:(void(^)(int removedCount, int totalCount))progress
                               endBlock:(void(^)(BOOL error))end {
    
    int total = [self _dbGetTotalItemCount];
    if (total <= 0) {
        if (end) end(total < 0);
    } else {
        int left = total;
        int perCount = 32;
        NSArray *items = nil;
        BOOL suc = NO;
        do {
            items = [self _dbGetItemSizeInfoOrderByTimeAscWithLimit:perCount];
            for (YYKVStorageItem *item in items) {
                if (left > 0) {
                    if (item.filename) {
                        [self _fileDeleteWithName:item.filename];
                    }
                    suc = [self _dbDeleteItemWithKey:item.key];
                    left--;
                } else {
                    break;
                }
                if (!suc) break;
            }
            if (progress) progress(total - left, total);
        } while (left > 0 && items.count > 0 && suc);
        if (suc) [self _dbCheckpoint];
        if (end) end(!suc);
    }
}

//读取缓存数据
/**
 该方法通过key访问数据，返回YYKVStorageItem封装的缓存数据。首先调用_dbGetItemWithKey:excludeInlineData:从数据库中查询
 
 最后取出YYKVStorageItem对象后，判断filename属性是否存在，
 如果存在说明缓存的二进制数据写进了文件中，此时返回的YYKVStorageItem对象的value属性是nil，
 需要调用_fileReadWithName:方法从文件中读取数据，并赋值给YYKVStorageItem的value属性。
 */
- (YYKVStorageItem *)getItemForKey:(NSString *)key {
    if (key.length == 0) return nil;
    YYKVStorageItem *item = [self _dbGetItemWithKey:key excludeInlineData:NO]; //从数据库中查询记录，返回YYKVStorageItem对象，封装了缓存数据的信息
    if (item) {
        [self _dbUpdateAccessTimeWithKey:key]; //更新访问时间
        if (item.filename) { //filename存在，按照item.value从文件中读取
            item.value = [self _fileReadWithName:item.filename];
            if (!item.value) {
                [self _dbDeleteItemWithKey:key];
                item = nil;
            }
        }
    }
    return item;
}

- (YYKVStorageItem *)getItemInfoForKey:(NSString *)key {
    if (key.length == 0) return nil;
    YYKVStorageItem *item = [self _dbGetItemWithKey:key excludeInlineData:YES];
    return item;
}

//读取缓存数据
/**
 该方法通过key访问缓存数据value，区分type，
 如果是YYKVStorageTypeSQLite，调用_dbGetValueWithKey:方法从数据库中查询key对应的记录中的inline_data。
 如果是YYKVStorageTypeFile，首先调用_dbGetFilenameWithKey:方法从数据库中查询key对应的记录中的filename，根据filename从文件中删除对应缓存数据。
 如果是YYKVStorageTypeMixed，同样先获取filename，根据filename是否存在选择用相应的方式访问
 */
- (NSData *)getItemValueForKey:(NSString *)key {
    if (key.length == 0) return nil;
    NSData *value = nil;
    switch (_type) {
        case YYKVStorageTypeFile: {
            NSString *filename = [self _dbGetFilenameWithKey:key]; //从数据库中查找filename
            if (filename) {
                value = [self _fileReadWithName:filename]; //根据filename读取数据
                if (!value) {
                    [self _dbDeleteItemWithKey:key]; //如果没有读取到缓存数据，从数据库中删除记录，保持数据同步
                    value = nil;
                }
            }
        } break;
        case YYKVStorageTypeSQLite: {
            value = [self _dbGetValueWithKey:key]; //直接从数据中取inline_data
        } break;
        case YYKVStorageTypeMixed: {
            NSString *filename = [self _dbGetFilenameWithKey:key]; //从数据库中查找filename
            if (filename) {
                value = [self _fileReadWithName:filename]; //根据filename读取数据
                if (!value) {
                    [self _dbDeleteItemWithKey:key]; //保持数据同步
                    value = nil;
                }
            } else {
                value = [self _dbGetValueWithKey:key]; //直接从数据中取inline_data
            }
        } break;
    }
    if (value) {
        [self _dbUpdateAccessTimeWithKey:key]; //更新访问时间 调用方法用于更新该数据的访问时间，即sql记录中的last_access_time字段。
    }
    return value;
}
/**
 返回一组YYKVStorageItem对象信息，调用_dbGetItemWithKeys:excludeInlineData:方法获取一组YYKVStorageItem对象。
 访问逻辑和getItemForKey:方法类似，sql语句的查询条件改为多个key匹配。
 */
- (NSArray *)getItemForKeys:(NSArray *)keys {
    if (keys.count == 0) return nil;
    NSMutableArray *items = [self _dbGetItemWithKeys:keys excludeInlineData:NO];
    if (_type != YYKVStorageTypeSQLite) {
        for (NSInteger i = 0, max = items.count; i < max; i++) {
            YYKVStorageItem *item = items[i];
            if (item.filename) {
                item.value = [self _fileReadWithName:item.filename];
                if (!item.value) {
                    if (item.key) [self _dbDeleteItemWithKey:item.key];
                    [items removeObjectAtIndex:i];
                    i--;
                    max--;
                }
            }
        }
    }
    if (items.count > 0) {
        [self _dbUpdateAccessTimeWithKeys:keys];
    }
    return items.count ? items : nil;
}

- (NSArray *)getItemInfoForKeys:(NSArray *)keys {
    if (keys.count == 0) return nil;
    return [self _dbGetItemWithKeys:keys excludeInlineData:YES];
}

/**
 返回一组缓存数据，调用getItemForKeys:方法获取一组YYKVStorageItem对象后，取出其中的value，存入一个临时字典对象后返回。
 */
- (NSDictionary *)getItemValueForKeys:(NSArray *)keys {
    NSMutableArray *items = (NSMutableArray *)[self getItemForKeys:keys];
    NSMutableDictionary *kv = [NSMutableDictionary new];
    for (YYKVStorageItem *item in items) {
        if (item.key && item.value) {
            [kv setObject:item.value forKey:item.key];
        }
    }
    return kv.count ? kv : nil;
}

- (BOOL)itemExistsForKey:(NSString *)key {
    if (key.length == 0) return NO;
    return [self _dbGetItemCountWithKey:key] > 0;
}

- (int)getItemsCount {
    return [self _dbGetTotalItemCount];
}

- (int)getItemsSize {
    return [self _dbGetTotalItemSize];
}

@end

//
//  iOS沙盒.m
//  iOS面试题总结
//
//  Created by Mobiyun on 2017/11/24.
//  Copyright © 2017年 冀凯旋. All rights reserved.
//

#import "iOS沙盒.h"

@implementation iOS__

/**
 
 1.Documents：只有用户生成的文件、应用程序不能重新创建的文件，应该保存在<Application_Home>/Documents 目录下面，并将通过iCloud自动备份。
 
 2.Library：可以重新下载或者重新生成的数据应该保存在<Application_Home>/Library/Caches 目录下面。举个例子，比如杂志、新闻、地图应用使用的数据库缓存文件和可下载内容应该保存到这个文件夹。
 
 3.tmp:只是临时使用的数据应该保存到<Application_Home>/tmp 文件夹。尽管 iCloud 不会备份这些文件，但在应用在使用完这些数据之后要注意随时删除，避免占用用户设备的空间
 
 
 //Home目录
 NSString *homeDirectory = NSHomeDirectory();
 
 //Document目录   documents (Documents)
 NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES);
 NSString *path = [paths objectAtIndex:0];
 
 //Libaray目录  various documentation, support, and configuration files, resources (Library)
 NSArray *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory,NSUserDomainMask,YES);
 NSString *path = [paths objectAtIndex:0];
 
 //Cache目录  location of discardable cache files (Library/Caches)
 NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory,NSUserDomainMask,YES);
 NSString *path = [paths objectAtIndex:0];
 

 
 */

@end

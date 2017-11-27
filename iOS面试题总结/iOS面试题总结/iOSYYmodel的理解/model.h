//
//  model.h
//  iOS面试题总结
//
//  Created by Mobiyun on 2017/11/24.
//  Copyright © 2017年 冀凯旋. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface model : NSObject

@property (copy, nonatomic) NSString *name;
@property (copy, nonatomic) NSString *email;
@property (copy, nonatomic) NSString *sex;
@property (copy, nonatomic) NSString *phone;

- (void)initSepModel:(NSDictionary *)dic;

@end

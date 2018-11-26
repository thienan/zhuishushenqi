//
//  ZSDBManager.m
//  zhuishushenqi
//
//  Created by caonongyun on 2018/11/22.
//  Copyright © 2018年 QS. All rights reserved.
//

#import "ZSDBManager.h"
#import <objc/runtime.h>
#import <FMDB/FMDB.h>

/** SQLite五种数据类型 */
#define SQLTEXT     @"TEXT"
#define SQLINTEGER  @"INTEGER"
#define SQLREAL     @"REAL"
#define SQLBLOB     @"BLOB"
#define SQLNULL     @"NULL"
#define PrimaryKey  @"primary key"

#define primaryId   @"pk"

@interface ZSDBManager ()

@property (nonatomic, strong) FMDatabaseQueue *dbQueue;

@end

@implementation ZSDBManager

+ (instancetype)share {
    static ZSDBManager *share = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        share = [[ZSDBManager alloc] init];
    });
    return share;
}

- (BOOL)isTableExist:(NSObject <ZSDBModel>*)model {
    __block BOOL res = NO;
    [self.dbQueue inDatabase:^(FMDatabase *db) {
        NSString *tableName = [model tableName];
        res = [db tableExists:tableName];
    }];
    return res;
}

- (NSArray *)getColumnsFrom:(NSObject <ZSDBModel>*)model {
    NSMutableArray *columns = [NSMutableArray array];
    [self.dbQueue inDatabase:^(FMDatabase *db) {
        NSString *tableName = NSStringFromClass(self.class);
        FMResultSet *resultSet = [db getTableSchema:tableName];
        while ([resultSet next]) {
            NSString *column = [resultSet stringForColumn:@"name"];
            [columns addObject:column];
        }
    }];
    return [columns copy];
}

+ (NSString *)getColumnAndTypeString:(NSArray <ZSDBPropertyModel *>*)models {
    NSMutableString *pars = [NSMutableString string];
    for (ZSDBPropertyModel *model in models) {
        if (![model.type isEqualToString:NSStringFromProtocol(@protocol(ZSDBModel))]) {
            if (model.mappingKey) {
                [pars appendString:model.mappingKey];
            } else {
                [pars appendString:model.originalKey];
            }
            [pars appendString:model.type];
            NSInteger count = [models indexOfObject:model];
            if (count != models.count - 1) {
                [pars appendString:@","];
            }
        }
    }
    return pars;
}

+ (BOOL)createTable:(NSObject <ZSDBModel>*)model
{
    __block BOOL res = YES;
    [ZSDBManager.share.dbQueue inTransaction:^(FMDatabase *db, BOOL *rollback) {
        NSString *tableName = [model tableName];
        NSArray <ZSDBPropertyModel *>* propertys = [[ZSDBManager share]getPropertys:model];
        NSString *columeAndType = [self.class getColumnAndTypeString:propertys];
        NSString *sql = [NSString stringWithFormat:@"CREATE TABLE IF NOT EXISTS %@(%@);",tableName,columeAndType];
        if (![db executeUpdate:sql]) {
            res = NO;
            *rollback = YES;
            return;
        };
        
        NSMutableArray *columns = [NSMutableArray array];
        FMResultSet *resultSet = [db getTableSchema:tableName];
        while ([resultSet next]) {
            NSString *column = [resultSet stringForColumn:@"name"];
            [columns addObject:column];
        }
        NSMutableArray *propertyStrings = @[].mutableCopy;
        for (ZSDBPropertyModel *model in propertys) {
            if (model.mappingKey) {
                [propertyStrings addObject:model.mappingKey];
            } else {
                [propertyStrings addObject:model.originalKey];
            }
        }
        
        NSPredicate *filterPredicate = [NSPredicate predicateWithFormat:@"NOT (SELF IN %@)",columns];
        //过滤数组
        NSArray *resultArray = [propertyStrings filteredArrayUsingPredicate:filterPredicate];
        for (NSString *column in resultArray) {
            NSUInteger index = [propertyStrings indexOfObject:column];
            NSString *proType = [[propertys objectAtIndex:index] type];
            if (![proType isEqualToString:NSStringFromProtocol(@protocol(ZSDBModel))]) {
                NSString *fieldSql = [NSString stringWithFormat:@"%@ %@",column,proType];
                NSString *sql = [NSString stringWithFormat:@"ALTER TABLE %@ ADD COLUMN %@ ",[model tableName],fieldSql];
                if (![db executeUpdate:sql]) {
                    res = NO;
                    *rollback = YES;
                    return ;
                }
            }
        }
    }];
    
    return res;
}

//- (BOOL)saveOrUpdate:(NSObject <ZSDBModel>*)model {
//    NSString *primaryKey = [model primaryKey];
//    id primaryValue = [model valueForKey:primaryKey];
//    if ([primaryValue intValue] <= 0) {
//        return [self save];
//    }
//    return [self update];
//}

- (NSArray *)queryAll:(NSObject <ZSDBModel>*)model {
    NSLog(@"ZSDBModel---%s",__func__);
    NSMutableArray *models = [NSMutableArray array];
    [self.dbQueue inDatabase:^(FMDatabase * _Nonnull db) {
        NSString *tableName = [model tableName];
        NSString *sql = [NSString stringWithFormat:@"SELECT * FROM %@",tableName];
        FMResultSet *resultSet = [db executeQuery:sql];
        while ([resultSet next]) {
            
        }
    }];
    return models;
}

- (NSArray <ZSDBPropertyModel *>*)getPropertys:(NSObject <ZSDBModel>*)model {
    NSString *foreignKey;
    NSString *primaryKey;
    NSDictionary <NSString *,NSString *> *mapping;
    NSArray <NSString *>*ignoredKeys;
    mapping = [model dbColumnMapping];
    primaryKey = [model primaryKey];
    foreignKey = [model foreignKey];
    ignoredKeys = [model ignoredKeys];
    NSMutableArray *propertys = @[].mutableCopy;
    unsigned int outCount, i;
    objc_property_t *properties = class_copyPropertyList([model class], &outCount);
    for (i = 0; i < outCount; i++) {
        objc_property_t property = properties[i];
        //获取属性名
        NSString *propertyName = [NSString stringWithCString:property_getName(property) encoding:NSUTF8StringEncoding];
        // 如果在忽略列表中,不处理
        if ([ignoredKeys containsObject:propertyName]) {
            continue;
        }
        id propertyValue = [model valueForKey:propertyName];
        ZSDBPropertyModel *propertyModel = [[ZSDBPropertyModel alloc] init];
        propertyModel.originalKey = propertyName;
        propertyModel.value = propertyValue;
        
        if (mapping[propertyName]) {
            propertyModel.mappingKey = mapping[propertyName];
        }
        if ([propertyName isEqualToString:primaryKey]) {
            propertyModel.isPrimaryKey = YES;
        } else {
            propertyModel.isPrimaryKey = NO;
        }
        
        if ([propertyValue conformsToProtocol:@protocol(ZSDBModel)]) {
            propertyModel.type = [NSString stringWithFormat:@"%@",@protocol(ZSDBModel)];
            propertyModel.value = [self getPropertys:propertyValue];
            continue;
        }
        //获取属性类型等参数
        NSString *propertyType = [NSString stringWithCString: property_getAttributes(property) encoding:NSUTF8StringEncoding];
        /*
         各种符号对应类型，部分类型在新版SDK中有所变化，如long 和long long
         c char         C unsigned char
         i int          I unsigned int
         l long         L unsigned long
         s short        S unsigned short
         d double       D unsigned double
         f float        F unsigned float
         q long long    Q unsigned long long
         B BOOL
         @ 对象类型 //指针 对象类型 如NSString 是@“NSString”
         
         
         64位下long 和long long 都是Tq
         SQLite 默认支持五种数据类型TEXT、INTEGER、REAL、BLOB、NULL
         因为在项目中用的类型不多，故只考虑了少数类型
         */
        if ([propertyType hasPrefix:@"T@\"NSString\""]) {
            propertyModel.type = SQLTEXT;
        } else if ([propertyType hasPrefix:@"T@\"NSData\""]) {
            propertyModel.type = SQLBLOB;
        } else if ([propertyType hasPrefix:@"Ti"]||[propertyType hasPrefix:@"TI"]||[propertyType hasPrefix:@"Ts"]||[propertyType hasPrefix:@"TS"]||[propertyType hasPrefix:@"TB"]||[propertyType hasPrefix:@"Tq"]||[propertyType hasPrefix:@"TQ"] || [propertyType hasPrefix:@"T@\"NSNumber\""]) {
            propertyModel.type = SQLINTEGER;
        } else {
            propertyModel.type = SQLREAL;
        }
    }
    return propertys;
}

+ (NSString *)dbPathWithDirectoryName:(NSString *)directoryName
{
    NSString *docsdir = [NSSearchPathForDirectoriesInDomains( NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    NSFileManager *filemanage = [NSFileManager defaultManager];
    if (directoryName == nil || directoryName.length == 0) {
        docsdir = [docsdir stringByAppendingPathComponent:@"zhuishushenqi"];
    } else {
        docsdir = [docsdir stringByAppendingPathComponent:directoryName];
    }
    BOOL isDir;
    BOOL exit =[filemanage fileExistsAtPath:docsdir isDirectory:&isDir];
    if (!exit || !isDir) {
        [filemanage createDirectoryAtPath:docsdir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    NSString *dbpath = [docsdir stringByAppendingPathComponent:@"zssq.sqlite"];
    return dbpath;
}

+ (NSString *)dbPath
{
    return [self dbPathWithDirectoryName:nil];
}

- (FMDatabaseQueue *)dbQueue
{
    if (_dbQueue == nil) {
        _dbQueue = [[FMDatabaseQueue alloc] initWithPath:[self.class dbPath]];
    }
    return _dbQueue;
}

@end
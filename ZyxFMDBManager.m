//
//  ZyxFMDBManager.m
//  EasyFMDB
//
//  Created by sytuzhouyong on 13-6-17.
//  Copyright (c) 2013年 sytuzhouyong. All rights reserved.
//

#import "ZyxFMDBManager.h"
#import "ZyxBaseModel.h"
#import "ZyxFieldAttribute.h"
#import "FMDB.h"

#define DBNAME @"EasyFMDB.db"

#define RANGE_SQL(__r) \
    __r.length == 0 ? @"" : [NSString stringWithFormat:@"limit %lu offset %lu", (unsigned long)__r.length, (unsigned long)__r.location]

#define EXECUTE_BLOCK1(__result) !block ?: block(__result)
#define EXECUTE_BLOCK2(__result, __array) !block ?: block(__result, __array)

@implementation ZyxFMDBManager {
    FMDatabaseQueue *_dbQueue;
}

SINGLETON_IMPLEMENTATION(ZyxFMDBManager);

- (void)createDBFileAtSubDirectory:(NSString *)subDirectory {
    @synchronized(self) {
        NSString *dbPath = [ZyxFMDBManager dbPathWithSubDirectory:subDirectory];
        
        if (_dbQueue == nil || _dbQueue.path.length == 0) {
            if (![[NSFileManager defaultManager] fileExistsAtPath:dbPath]) {
                [ZyxFMDBManager createTablesInDBPath:dbPath];
            } else {
                FMDatabase *db = [[FMDatabase alloc] initWithPath:dbPath];
                if (![db open]) {
                    LogError(@"oh no, open db in (%@) failed!", dbPath);
                    exit(0);
                }
                
                [ZyxFMDBManager updateTableInDB:db];
                [db close];
            }
        } else if (![dbPath isEqualToString:_dbQueue.path]) {
            [_dbQueue close];
        }
        
        _dbQueue = [[FMDatabaseQueue alloc] initWithPath:dbPath];
        LogInfo(@"dbPath = %@", dbPath);
    }
}

#pragma mark - Create and Update Tables

+ (void)createTablesInDBPath:(NSString *)dbPath {
    do {
        FMDatabase *db = [[FMDatabase alloc] initWithPath:dbPath];
        if (![db open]) {
            LogError(@"oh no, open db in (%@) failed!", dbPath);
            break;
        }
        
        NSMutableSet *registedModels = [ZyxBaseModel registedModels];
        for (NSString *value in registedModels) {
            Class clazz = NSClassFromString(value);
            NSString *sql = [clazz sql];
            
            if (![db executeUpdate:sql]) {
                LogError(@"oh no, create table(%@) failed!", TABLE_NAME_C(clazz));
                break;
            }
        }
        
        [db close];
        
        LogGreen(@"create table success!");
        return;
    }
    while (NO);
    
    LogError(@"oh no, create table failed!");
    exit(0);
}

+ (void)updateTableInDB:(FMDatabase *)db {
    NSSet *registedModels = [ZyxBaseModel registedModels];
    for (NSString *value in registedModels) {
        NSString *tableName = TABLE_NAME_S(value);
        
        // if table isn't exist, create it
        Class clazz = NSClassFromString(value);
        if (![db tableExists:tableName]) {
            if (![db executeUpdate:[clazz sql]]) {
                LogError(@"oh no, create table (%@) failed!", tableName);
                exit(0);
            }
        } else {
            NSMutableDictionary *propertyDict = [NSMutableDictionary dictionaryWithDictionary:[clazz propertiesDictionary]];
            FMResultSet *rs = [db getTableSchema:tableName];
            
            //check if column is present in table schema
            while ([rs next]) {
                NSString *dbName = [rs stringForColumn:@"name"];
                NSString *propertyName = [ZyxBaseModel dbNameToPropertyName:dbName];
                [propertyDict removeObjectForKey:propertyName];
            }
            [rs close];
            
            // all columns in table are the same with properties in model
            if (propertyDict.count == 0) {
                return;
            }
            
            // there are new declared properties in model, so update them into table
            if (![db beginTransaction]) {
                LogError(@"db begin transaction failed!");
                exit(0);
            }
            
            NSArray *properties = [propertyDict allValues];
            for (ZyxFieldAttribute *item in properties) {
                NSString *sql = [NSString stringWithFormat:@"alter table %@ add column %@ %@", tableName, item.nameInDB, [ZyxDataType stringWithDataType:item.type]];
                
                if (![db executeUpdate:sql]) {
                    LogError(@"oh no, add column to db failed, sql:[%@], errro code:%d, error message:%@", sql, db.lastErrorCode, db.lastErrorMessage);
                    exit(0);
                }
            }
            
            if (![db commit]) {
                LogError(@"db commit failed!");
                exit(0);
            }
        }
    }
}

#pragma mark - Add Model

- (BOOL)addModel:(ZyxBaseModel *)model inDatabase:(FMDatabase *)db {
    NSString *sql = [self makeInsertSQL:model];
    BOOL result = [self database:db executeUpdate:sql withArgumentsInArray:[model updatedValuesExceptId]];
    if (!result) {
        LogError(@"db add model %@ failed, error code: %d, erro message: %@", model, db.lastErrorCode, db.lastErrorMessage);
    } else {
        NSUInteger last = (NSUInteger)[db lastInsertRowId];
        LogInfo(@"last insert row id = %lu, in table : %@", (unsigned long)last, TABLE_NAME(model));
        model.id = last;
    }
    return result;
}

- (void)addModel:(ZyxBaseModel *)model result:(DBUpdateOperationResultBlock)block {
    NSArray *properties = [model updatedPropertiesExceptId];
    NSDictionary *propertyDict = [model.class propertiesDictionary];
    
    NSMutableArray *tobeAddedModels = [NSMutableArray array];
    for (NSString *key in properties) {
        ZyxFieldAttribute *p = propertyDict[key];
        if (p.isBaseModel) {
            ZyxBaseModel *subModel = [model valueForKey:key];
            if (subModel.id == 0) {
                [tobeAddedModels addObject:subModel];
            }
        }
    }
    [tobeAddedModels addObject:model];
    
    [_dbQueue inTransaction:^(FMDatabase *db, BOOL *rollback) {
        BOOL result = YES;
        for (ZyxBaseModel *item in tobeAddedModels) {
            result &= [self addModel:item inDatabase:db];
            if (!result) {
                LogError(@"add model[%@] failed!", item);
                *rollback = YES;
                break;
            }
        }
        EXECUTE_BLOCK1(result);
    }];
}

- (void)addModels:(NSArray *)models result:(DBUpdateOperationResultBlock)block {
    [_dbQueue inTransaction:^(FMDatabase *db, BOOL *rollback) {
        BOOL result = YES;
        for (ZyxBaseModel *item in models) {
            result &= [self addModel:item inDatabase:db];
            if (!result) {
                LogError(@"add model[%@] failed!", item);
                *rollback = YES;
                break;
            }
        }
        EXECUTE_BLOCK1(result);
    }];
}

- (void)add:(id)model result:(DBUpdateOperationResultBlock)block {
    if ([model isKindOfClass:ZyxBaseModel.class]) {
        [self addModel:model result:block];
    } else if ([model isKindOfClass:NSArray.class]) {
        [self addModels:model result:block];
    }
}

#pragma mark - Update Model

// update by id
- (void)updateModel:(ZyxBaseModel *)model result:(DBUpdateOperationResultBlock)block {
    NSArray *array = [self makeUpdateSQLByIdInModel:model];
    
    [_dbQueue inDatabase:^(FMDatabase *db) {
        NSString *sql = [array objectAtIndex:0];
        NSArray *updatedValues = [array objectAtIndex:2];
        BOOL result = [db executeUpdate:sql withArgumentsInArray:updatedValues];
        [self checkUpdateSQLResult:db];
        
        EXECUTE_BLOCK1(result);
    }];
}

// update every model in array by id
- (void)updateModels:(NSArray *)models result:(DBUpdateOperationResultBlock)block
{
    [_dbQueue inTransaction:^(FMDatabase *db, BOOL *rollback) {
        BOOL result = YES;
        for (ZyxBaseModel *model in models) {
            NSArray *sqlArray = [self makeUpdateSQLByIdInModel:model];
            NSString *sql = [sqlArray objectAtIndex:0];
            NSArray *updatedValues = [sqlArray objectAtIndex:2];
            result &= [db executeUpdate:sql withArgumentsInArray:updatedValues];
            [self checkUpdateSQLResult:db];
        }
        if (!result) {
            *rollback = YES;
        }
        
        EXECUTE_BLOCK1(result);
    }];
}

// update model by update properties and query properties
// eg. update Model set a=?, b=? where c = c or/and d like d
- (void)updateModel:(ZyxBaseModel *)model
   updateProperties:(NSArray *)updates
    queryProperties:(NSArray *)queries
            matches:(NSArray *)matches
             logics:(NSArray *)logics
             result:(DBUpdateOperationResultBlock)block {
    if (updates.count == 0) {
        LogWarning(@"oh no, update with no property");
        EXECUTE_BLOCK1(NO);
    }
    
    [_dbQueue inDatabase:^(FMDatabase *db) {
        NSArray *array = [self makeUpdateSQL:model updateProperties:updates queryProperties:queries matches:matches logics:logics];
        NSString *sql = [array objectAtIndex:0];
        NSArray *values = [array objectAtIndex:2];
        BOOL result = [db executeUpdate:sql withArgumentsInArray:values];
        [self checkUpdateSQLResult:db];
        EXECUTE_BLOCK1(result);
    }];
}

// update model by update properties and query properties
// eg. update Model set a=?, b=? where c = c or c = cc
- (void)updateModel:(ZyxBaseModel *)model
   updateProperties:(NSArray *)updates
queryPropertiesAndValues:(NSDictionary *)queries
            matches:(NSArray *)matches
             logics:(NSArray *)logics
             result:(DBUpdateOperationResultBlock)block {
    if (updates.count == 0) {
        LogWarning(@"oh no, update with no property");
        EXECUTE_BLOCK1(NO);
    }
    
    [_dbQueue inDatabase:^(FMDatabase *db) {
        NSArray *array = [self makeUpdateSQL:model updateProperties:updates queryProperties:queries matches:matches logics:logics];
        NSString *sql = [array objectAtIndex:0];
        NSArray *values = [array objectAtIndex:2];
        
        BOOL result = [db executeUpdate:sql withArgumentsInArray:values];
        [self checkUpdateSQLResult:db];
        EXECUTE_BLOCK1(result);
    }];
}

- (BOOL)update:(id)param result:(DBUpdateOperationResultBlock)block {
    if ([param isKindOfClass:ZyxBaseModel.class]) {
        [self updateModel:param result:block];
    } else if ([param isKindOfClass:NSArray.class]) {
        [self updateModels:param result:block];
    } else if ([param isKindOfClass:NSDictionary.class]) {
        NSDictionary *dict = param;
        ZyxBaseModel *model = dict[kEasyFMDBModel];
        if (model == nil) {
            LogError(@"oh no, kEasyFMDBModel in dict(%@) is nil!", dict);
            return NO;
        }
        
        NSArray *matches = [self arrayInDictionary:dict forKey:kEasyFMDBMatches];
        NSArray *logics = [self arrayInDictionary:dict forKey:kEasyFMDBLogics];
        
        id u = dict[kEasyFMDBUpdateProperties];
        id q1 = dict[kEasyFMDBQueryProperties];
        id q2 = dict[kEasyFMDBQueryPropertiesAndValues];
        
        if (u == nil) {
            NSArray *updates = [model updatedPropertiesExceptId];
            NSDictionary *queries = [self combineQueryInfoInDictionary:dict ofModel:model];
            if (queries.count != 0) {
                [self updateModel:model updateProperties:updates queryPropertiesAndValues:queries matches:matches logics:logics result:block];
            } else if (model.id != 0) {
                [self updateModel:model result:block];
            } else {
                LogError(@"oh no, nil kEasyFMDBQueryProperties and nil kEasyFMDBQueryProperties* in dict(%@), "
                         "but id in model(%@) is 0!", dict, model);
                return NO;
            }
        } else {
            NSArray *updates = [self arrayInDictionary:dict forKey:kEasyFMDBUpdateProperties];
            if (updates == nil) {
                LogError(@"oh no, invalid param of kEasyFMDBUpdateProperties in dict(%@)", dict);
                return NO;
            }
            
            if (q1 != nil || q2 != nil) {
                NSDictionary *queries = [self combineQueryInfoInDictionary:dict ofModel:model];
                [self updateModel:model updateProperties:updates queryPropertiesAndValues:queries matches:matches logics:logics result:block];
            } else {
                [self updateModel:model updateProperties:updates queryProperties:@[@"id"] matches:matches logics:logics result:block];
            }
        }
    }
    return YES;
}

#pragma mark - Delete Model

- (void)deleteModel:(ZyxBaseModel *)model result:(DBUpdateOperationResultBlock)block {
    [_dbQueue inDatabase:^(FMDatabase *db) {
        BOOL result = NO;
        NSString *sql = nil;
        if (model.id != 0) {
            sql = [NSString stringWithFormat:@"delete from %@ where id=%lu", TABLE_NAME(model), (unsigned long)model.id];
            result = [db executeUpdate:sql];
        } else {
            NSDictionary *dict = @{kEasyFMDBProperties:[model updatedPropertiesExceptId],
                                   kEasyFMDBValues:[model updatedValuesExceptId]};
            NSArray *array = [self makeQueryPredicateSql:model withParam:dict];
            NSString *sql = [array objectAtIndex:0];
            NSString *logSql = [array objectAtIndex:1];
            NSArray *values = [array objectAtIndex:2];
            
            sql = [NSString stringWithFormat:@"delete from %@ where %@", TABLE_NAME(model), sql];
            logSql = [NSString stringWithFormat:@"delete from %@ where %@", TABLE_NAME(model), logSql];
            LogInfo(@"delete sql:%@", logSql);
            result = [db executeUpdate:sql withArgumentsInArray:values];
        }
        [self checkUpdateSQLResult:db];
        EXECUTE_BLOCK1(result);
    }];
}

- (void)deleteModels:(NSArray *)models result:(DBUpdateOperationResultBlock)block {
    [_dbQueue inTransaction:^(FMDatabase *db, BOOL *rollback) {
        BOOL result = YES;
        for (ZyxBaseModel *model in models) {
            NSString *sql = [NSString stringWithFormat:@"delete from %@ where id=%lu", TABLE_NAME(model), (unsigned long)model.id];
            LogInfo(@"delete sql: %@", sql);
            result &= [db executeUpdate:sql];
            [self checkUpdateSQLResult:db];
        }
        EXECUTE_BLOCK1(result);
    }];
}

- (void)deleteAllModelsInTable:(Class)c result:(DBUpdateOperationResultBlock)block {
    [_dbQueue inDatabase:^(FMDatabase *db) {
        NSString *sql = [NSString stringWithFormat:@"delete from %@", TABLE_NAME_C(c)];
        BOOL result = [db executeUpdate:sql];
        LogInfo(@"delete all sql: %@", sql);
        [self checkUpdateSQLResult:db];
        EXECUTE_BLOCK1(result);
    }];
}

- (void)deleteModel:(ZyxBaseModel *)model
            matches:(NSArray *)matches
             logics:(NSArray *)logics
             result:(DBUpdateOperationResultBlock)block {
    NSArray *properties = [model updatedProperties];
    if (properties.count == 0) {
        [self deleteAllModelsInTable:model.class result:block];
        return;
    }
    
    [_dbQueue inDatabase:^(FMDatabase *db) {
        NSArray *propertiesValues = [model updatedValues];
        NSDictionary *dict = @{kEasyFMDBProperties: properties,
                               kEasyFMDBValues: propertiesValues,
                               kEasyFMDBMatches:(matches == nil ? @(DCT_Equal) : matches),
                               kEasyFMDBLogics:(logics == nil ? @(LR_And) : logics)};
        NSArray *array = [self makeQueryPredicateSql:model withParam:dict];
        NSString *sql = [array objectAtIndex:0];
        NSString *logSql = [array objectAtIndex:1];
        NSArray *values = [array objectAtIndex:2];
        
        sql = [NSString stringWithFormat:@"delete from %@ where %@", TABLE_NAME(model), sql];
        logSql = [NSString stringWithFormat:@"delete from %@ where %@", TABLE_NAME(model), logSql];
        LogInfo(@"delete sql: %@", logSql);
        BOOL result = [db executeUpdate:sql withArgumentsInArray:values];
        [self checkUpdateSQLResult:db];
        EXECUTE_BLOCK1(result);
    }];
}

- (void)deleteModel:(ZyxBaseModel *)model
queryPropertiesAndValues:(NSDictionary *)queries
            matches:(NSArray *)matches
             logics:(NSArray *)logics
             result:(DBUpdateOperationResultBlock)block {
    [_dbQueue inDatabase:^(FMDatabase *db) {
        NSDictionary *dict = @{kEasyFMDBProperties: queries.allKeys,
                               kEasyFMDBValues: queries.allValues,
                               kEasyFMDBMatches:(matches == nil ? @(DCT_Equal) : matches),
                               kEasyFMDBLogics:(logics == nil ? @(LR_And) : logics)};
        NSArray *array = [self makeQueryPredicateSql:model withParam:dict];
        NSString *sql = [array objectAtIndex:0];
        NSString *logSql = [array objectAtIndex:1];
        NSArray *values = [array objectAtIndex:2];
        
        sql = [NSString stringWithFormat:@"delete from %@ where %@", TABLE_NAME(model), sql];
        logSql = [NSString stringWithFormat:@"delete from %@ where %@", TABLE_NAME(model), logSql];
        LogInfo(@"delete sql: %@", logSql);
        BOOL result = [db executeUpdate:sql withArgumentsInArray:values];
        [self checkUpdateSQLResult:db];
        EXECUTE_BLOCK1(result);
    }];
}

- (void)delete:(id)param result:(DBUpdateOperationResultBlock)block {
    if ([param isKindOfClass:ZyxBaseModel.class]) {
        ZyxBaseModel *model = param;
        // just a default ZyxBaseModel object
        if (model.updatedProperties.count <= 0) {
            [self deleteAllModelsInTable:model.class result:block];
        } else {
            [self deleteModel:param result:block];
        }
    } else if ([param isKindOfClass:NSArray.class]) {
        [self deleteModels:param result:block];
    } else if ([param isKindOfClass:NSValue.class]) {
        [self deleteAllModelsInTable:[param pointerValue] result:block];
    } else if ([param isKindOfClass:NSDictionary.class]) {
        NSDictionary *dict = param;
        id model = dict[kEasyFMDBModel];
        if ([model isKindOfClass:NSValue.class]) {
            [self deleteAllModelsInTable:[model pointerValue] result:block];
        } else {
            NSArray *matches = [self arrayInDictionary:dict forKey:kEasyFMDBMatches];
            NSArray *logics = [self arrayInDictionary:dict forKey:kEasyFMDBLogics];
            
            NSDictionary *queries = [self combineQueryInfoInDictionary:dict ofModel:model];
            if (queries.count == 0) {
                [self deleteModel:model matches:matches logics:logics result:block];
            } else {
                [self deleteModel:model queryPropertiesAndValues:queries matches:matches logics:logics result:block];
            }
        }
    }
}

#pragma mark - Query Model

// query all models in table
- (void)queryAllModels:(Class)c
                orders:(NSDictionary *)orders
                 range:(NSRange)range
                result:(DBQueryOperationResultBlock)block {
    NSString *orderSQL = [self makeOrderSQL:c orders:orders];
    NSString *rangeSQL = RANGE_SQL(range);
    NSString *sql = [NSString stringWithFormat:@"select * from %@ %@ %@", TABLE_NAME_C(c), orderSQL, rangeSQL];
    sql = [sql stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    LogInfo(@"queryAll sql: %@", sql);
    NSArray *array = [self executeQuery:c withSQL:sql values:[NSArray array]];
    EXECUTE_BLOCK2(array != nil, array);
}

// query models in condition
- (void)queryModel:(ZyxBaseModel *)model
  propertiesValues:(NSDictionary *)propertiesValues
           matches:(NSArray *)matches
            logics:(NSArray *)logics
            orders:(NSDictionary *)orders
             range:(NSRange)range
            result:(DBQueryOperationResultBlock)block {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (matches.count != 0) {
        dict[kEasyFMDBMatches] = matches;
    }
    if (logics.count != 0) {
        dict[kEasyFMDBLogics] = logics;
    }
    
    // must be in order, because match value of property is ordered
    NSMutableArray *updatedProperties = [NSMutableArray arrayWithArray:model.updatedProperties];
    NSMutableArray *updatedValues = [NSMutableArray arrayWithArray:model.updatedValues];
    [updatedProperties addObjectsFromArray:propertiesValues.allKeys];
    [updatedValues addObjectsFromArray:propertiesValues.allValues];
    dict[kEasyFMDBProperties] = updatedProperties;
    dict[kEasyFMDBValues] = updatedValues;
    
    NSArray *sqlArray = [self makeQueryPredicateSql:model withParam:dict];
    NSString *sql = [sqlArray objectAtIndex:0];
    NSString *logSQL = [sqlArray objectAtIndex:1];
    NSArray *values = [sqlArray objectAtIndex:2];
    
    NSString *orderSQL = [self makeOrderSQL:model.class orders:orders];
    NSString *rangeSQL = RANGE_SQL(range);
    sql = [NSString stringWithFormat:@"select * from %@ where %@ %@ %@", TABLE_NAME(model), sql, orderSQL, rangeSQL];
    logSQL = [NSString stringWithFormat:@"select * from %@ where %@ %@ %@", TABLE_NAME(model), logSQL, orderSQL, rangeSQL];
    LogInfo(@"select sql: %@", logSQL);
    
    NSArray *array = [self executeQuery:model.class withSQL:sql values:values];
    EXECUTE_BLOCK2(array != nil, array);
}

- (void)query:(id)param result:(DBQueryOperationResultBlock)block {
    NSDictionary *propertiesValues = nil;
    NSArray *matches = nil;
    NSArray *logics = nil;
    NSDictionary *orders = nil;
    NSRange range = NSMakeRange(0, 0);
    
    if ([param isKindOfClass:ZyxBaseModel.class]) {
        [self queryModel:param propertiesValues:nil matches:nil logics:nil orders:nil range:range result:block];
    } else if ([param isKindOfClass:NSValue.class]) {
        [self queryAllModels:[param pointerValue] orders:nil range:range result:block];
    } else if ([param isKindOfClass:NSDictionary.class]) {
        NSDictionary *dict = param;
        id model = dict[kEasyFMDBModel];
        
        if ([model isKindOfClass:NSValue.class]) {
            [self queryAllModels:[model pointerValue] orders:nil range:range result:block];
            return;
        }
        
        if (![self parseQueryParam:param propertiesValues:&propertiesValues matches:&matches logics:&logics orders:&orders range:&range]) {
            LogError(@"parse query param(%@) failed!", param);
            return;
        }
        
        [self queryModel:model propertiesValues:propertiesValues matches:matches logics:logics orders:orders range:range result:block];
    }
}

#define CASE_DTTYPE_1(__type, __func1) \
    case DT_##__type: { \
        __type v = (__type)[result __func1:p.nameInDB]; \
        [bm setValue:@(v) forKey:name]; \
        break; \
    }\

#define CASE_DTTYPE_2(__type, __func) \
    case DT_##__type: { \
        __type *v = (__type *)[result __func:p.nameInDB]; \
        [bm setValue:v forKey:name]; \
        break; \
    }\

// 查询功能函数
- (NSArray *)executeQuery:(Class)c withSQL:(NSString *)sql values:(NSArray *)values {
    __block NSArray *array = [[NSArray alloc] init];
    [_dbQueue inDatabase:^(FMDatabase *db) {
        array = [self executeQuery:c withSQL:sql values:values inDatabase:db];
    }];
    return array;
}

- (NSArray *)executeQuery:(Class)c withSQL:(NSString *)sql values:(NSArray *)values inDatabase:(FMDatabase *)db {
    NSMutableArray *array = [[NSMutableArray alloc] init];
    NSDictionary *propertyDict = [c propertiesDictionary];
    
    FMResultSet *result = nil;
    if (!values || [values count] == 0) {
        result = [db executeQuery:sql];
    } else {
        result = [db executeQuery:sql withArgumentsInArray:values];
    }
    
    while ([result next]) {
        ZyxBaseModel *bm = [[c alloc] initWithObserverEnabledFlag:NO];
        for (NSString *name in propertyDict.allKeys)
        {
            ZyxFieldAttribute *p = [propertyDict objectForKey:name];
            switch (p.type)
            {
                    CASE_DTTYPE_1(BOOL, boolForColumn);
                    CASE_DTTYPE_1(NSInteger, longLongIntForColumn);
                    CASE_DTTYPE_1(NSUInteger, unsignedLongLongIntForColumn);
                    CASE_DTTYPE_1(CGFloat, doubleForColumn);
                    CASE_DTTYPE_2(NSDate, dateForColumn);
                    CASE_DTTYPE_2(NSString, stringForColumn);
                case DT_ZyxBaseModel: {
                    Class clazz = NSClassFromString(p.className);
                    
                    NSUInteger modelId = (NSUInteger)[result unsignedLongLongIntForColumn:p.nameInDB];
                    NSString *sql = [NSString stringWithFormat:@"select * from %@ where id=%lu", TABLE_NAME_S(p.className), (unsigned long)modelId];
                    NSArray *models = [self executeQuery:clazz withSQL:sql values:nil inDatabase:db];
                    if (models.count != 0) {
                        ZyxBaseModel *model = models.firstObject;
                        [bm setValue:model forKey:name];
                    }
                    
                    break;
                }
                default: {
                    LogWarning(@"unrecognized data type(%lu)!", (unsigned long)p.type);
                    break;
                }
            }
        }
        [bm setObserverEnabled:YES];
        [array addObject:bm];
    }
    [result close];
    
    return array;
}

#pragma mark - Function Method

// make query sql of model
// eg (where) a=? or/and a=? or/and b=?
- (NSArray *)makeQueryPredicateSql:(ZyxBaseModel *)model withParam:(NSDictionary *)dict {
    NSArray *properties = dict[kEasyFMDBProperties];
    NSArray *values     = dict[kEasyFMDBValues];
    NSArray *matches    = dict[kEasyFMDBMatches];
    NSArray *logics     = dict[kEasyFMDBLogics];
    if (matches != nil && ![matches isKindOfClass:NSArray.class]) {
        matches = @[matches];
    }
    if (logics != nil && ![logics isKindOfClass:NSArray.class]) {
        logics = @[logics];
    }
    
    NSUInteger valuesCount = values.count;
    // adjust array of logics
    if (logics.count < valuesCount) {
        NSMutableArray *newLogics = [NSMutableArray arrayWithArray:logics];
        for (NSUInteger i=logics.count; i<valuesCount; i++) {
            [newLogics addObject:@(LR_And)];
        }
        logics = [NSArray arrayWithArray:newLogics];
    }
    
    // adjust array of matches
    if (matches.count < valuesCount) {
        NSMutableArray *newMatches = [NSMutableArray arrayWithArray:matches];
        for (NSUInteger i=matches.count; i<valuesCount; i++) {
            id value = values[i];
            // property have more than 1 value, eg: propertyA = 1 or propertyA = 2
            if ([value isKindOfClass:NSArray.class]) {
                NSArray *propertyValues = (NSArray *)value;
                NSMutableArray *propertyMatches = [NSMutableArray arrayWithCapacity:propertyValues.count];
                for (NSUInteger k=0; k<propertyValues.count; k++) {
                    [propertyMatches addObject:@(DCT_Equal)];
                }
                [newMatches addObject:propertyMatches];
            } else {
                [newMatches addObject:@(DCT_Equal)];
            }
        }
        matches = [NSArray arrayWithArray:newMatches];
    }
    
    // PropertyName : ZyxFieldAttribute
    NSDictionary *propertyDict = [model.class propertiesDictionary];
    NSString *logic = @"";
    
    NSMutableArray *propertiesValues = [[NSMutableArray alloc] initWithCapacity:valuesCount];
    
    NSMutableString *sql = [[NSMutableString alloc] initWithString:@""];
    NSMutableString *logSQL = [[NSMutableString alloc] initWithString:@""];
    NSUInteger index = 0;
    for (NSUInteger i=0; i<valuesCount; i++) {
        NSString *property = [properties objectAtIndex:i];
        if (property.length == 0) {
            LogWarning(@"property at index %lu is empty", (unsigned long)i);
            continue;
        }
        
        ZyxFieldAttribute *p = [propertyDict objectForKey:property];
        if (p == nil) {
            LogWarning(@"update unknown property(%@) in class(%@)", property, NSStringFromClass(model.class));
            continue;
        }
        
        id value = [values objectAtIndex:i];
        NSArray *propertyValues = [value isKindOfClass:NSArray.class] ? value : @[value];
        NSUInteger propertyValuesCount = propertyValues.count;
        if (propertyValuesCount == 0) {
            LogWarning(@"property values of property %@ at index %lu is empty", property, (unsigned long)i);
            continue;
        }
        
        id match = matches[i];
        NSMutableArray *propertyMatches = [NSMutableArray arrayWithArray:([match isKindOfClass:NSArray.class] ? match : @[match])];
        for (NSUInteger k=propertyMatches.count; k<propertyValuesCount; k++) {
            [propertyMatches addObject:@(DCT_Equal)];
        }
        
        [sql appendString:@"("];
        [logSQL appendString:@"("];
        
        // one property contains many values
        // eg. a = a or a like %aa% or a != aaa
        for (NSUInteger j=0; j<propertyValuesCount; j++) {
            EDataCompareType matchType = [[propertyMatches objectAtIndex:j] intValue];
            NSString *match = [self stringWithMatchType:matchType];
            
            id value = [propertyValues objectAtIndex:j];
            id logValue = value;
            if ([value isKindOfClass:NSString.class] && matchType == DCT_Like) { // %test%
                value = [NSString stringWithFormat:@"%%%@%%", value];
                [propertiesValues addObject:value];
            }
            else if ([value isKindOfClass:ZyxBaseModel.class]) {
                id idValue = [value valueForKey:@"id"];
                [propertiesValues addObject:idValue];
                logValue = idValue;
            } else {
                [propertiesValues addObject:value];
            }
            [sql appendFormat:@"%@ %@ ? or ", p.nameInDB, match];
            [logSQL appendFormat:@"%@ %@ %@ or ", p.nameInDB, match, logValue];
            
            index++;
        }
        
        [sql setString:[sql substringToIndex:sql.length - 4]];  // delete ' or '
        [logSQL setString:[logSQL substringToIndex:logSQL.length - 4]];
        
        ELogicRelationship logicType = [[logics objectAtIndex:i] intValue];
        logic = logicType == LR_Or ? @"or" : @"and";
        
        [sql appendFormat:@") %@ ", logic];
        [logSQL appendFormat:@") %@ ", logic];
    }
    
    if (sql.length > 0) {
        [sql setString:[sql substringToIndex:sql.length - logic.length - 2]];   // delete ' logic '
        [logSQL setString:[logSQL substringToIndex:logSQL.length - logic.length - 2]];
    }
    
    return @[sql, logSQL, propertiesValues];
}

// make the assignment sql of updated properties
- (NSArray *)makeAssignmentSqlOfModel:(ZyxBaseModel *)model withUpdatedProperties:(NSArray *)updatedPropertes {
    NSDictionary *propertyDict = [model.class propertiesDictionary];
    
    NSUInteger updateCount = updatedPropertes.count;
    NSMutableArray *values = [[NSMutableArray alloc] initWithCapacity:updateCount];
    
    NSMutableString *sql = [NSMutableString string];
    NSMutableString *logSQL = [NSMutableString string];
    for (NSUInteger i=0; i<updateCount; i++) {
        NSString *property = updatedPropertes[i];
        if (property.length == 0) {
            LogWarning(@"oh no, property %@ at index %lu is nil", updatedPropertes, (unsigned long)i);
            continue;
        }
        if ([property isEqualToString:@"id"]) {
            continue;
        }
        
        id value = [model valueForKey:property];
        if (value == nil || [value isKindOfClass:NSNull.class])
            continue;
        
        // 如果更新BaseModel, 则只需要更新BaseModel的id
        if ([value isKindOfClass:ZyxBaseModel.class]) {
            [values addObject:[value valueForKey:@"id"]];
        } else {
            [values addObject:value];
        }
        
        ZyxFieldAttribute *p = propertyDict[property];
        [sql appendFormat:@"%@ = ?, ", p.nameInDB];
        
        id value2 = value;
        if ([value isKindOfClass:NSString.class]) {
            NSString *valueString = value;
            if (valueString.length > 150) {
                value2 = [valueString substringToIndex:150];
            }
        }
        [logSQL appendFormat:@"%@ = %@, ", p.nameInDB, value2];
    }
    
    if (sql.length > 0) {
        [sql setString:[sql substringToIndex:sql.length - 2]];
        [logSQL setString:[logSQL substringToIndex:logSQL.length - 2]];
    }
    
    return @[sql, logSQL, values];
}

// make update sql of model by id
- (NSArray *)makeUpdateSQLByIdInModel:(ZyxBaseModel *)model {
    NSArray *updates = [model updatedPropertiesExceptId];
    NSArray *queries = @[@"id"];
    NSArray *result = [self makeUpdateSQL:model updateProperties:updates queryProperties:queries matches:nil logics:nil];
    return result;
}

// make update sql by update properties and query properties
- (NSArray *)makeUpdateSQL:(ZyxBaseModel *)model
          updateProperties:(NSArray *)updates
           queryProperties:(id)queries
                   matches:(NSArray *)matches
                    logics:(NSArray *)logics {
    NSUInteger updateCount = updates.count;
    NSMutableArray *values = [[NSMutableArray alloc] initWithCapacity:updateCount];
    
    // update sql
    NSArray *updateArray = [self makeAssignmentSqlOfModel:model withUpdatedProperties:updates];
    NSString *updateSQL = [updateArray objectAtIndex:0];
    NSString *updateLogSQL = [updateArray objectAtIndex:1];
    NSArray *updateValues = [updateArray objectAtIndex:2];
    [values addObjectsFromArray:updateValues];
    
    NSMutableArray *queryProperties = [[NSMutableArray alloc] initWithCapacity:8];
    NSMutableArray *queryPropertiesValues = [[NSMutableArray alloc] initWithCapacity:8];
    
    if ([queries isKindOfClass:NSArray.class]) {
        [queryProperties addObjectsFromArray:queries];
        for (NSString *property in queries) {
            [queryPropertiesValues addObject:[model valueForKey:property]];
        }
    } else if ([queries isKindOfClass:NSDictionary.class]) {
        NSDictionary *dict = queries;
        [queryProperties addObjectsFromArray:dict.allKeys];
        [queryPropertiesValues addObjectsFromArray:dict.allValues];
    } else {
        LogWarning(@"makeUpdateSQL param queries(%@) is not a valid object", queries);
        return @[@"", @"", @[]];
    }
    
    // query sql
    NSDictionary *dict = @{kEasyFMDBProperties:queryProperties,
                           kEasyFMDBValues:queryPropertiesValues,
                           kEasyFMDBMatches:(matches == nil ? @(DCT_Equal) : matches),
                           kEasyFMDBLogics:(logics == nil ? @(LR_And) : logics)};
    NSArray *queryArray = [self makeQueryPredicateSql:model withParam:dict];
    NSString *querySQL = [queryArray objectAtIndex:0];
    NSString *queryLogSQL = [queryArray objectAtIndex:1];
    NSArray *queryValues = [queryArray objectAtIndex:2];
    [values addObjectsFromArray:queryValues];
    
    
    // complete sql
    NSString *tableName = TABLE_NAME(model);
    NSString *sql = [NSString stringWithFormat:@"update %@ set %@ where %@", tableName, updateSQL, querySQL];
    NSString *logSQL = [NSString stringWithFormat:@"update %@ set %@ where %@", tableName, updateLogSQL, queryLogSQL];
    LogInfo(@"update sql: %@", logSQL);
    
    return @[sql, logSQL, values];
}

- (NSString *)makeInsertSQL:(ZyxBaseModel *)model {
    NSArray *properties = [model updatedPropertiesExceptId];
    NSDictionary *propertyDict = [model.class propertiesDictionary];
    
    NSMutableString *psql = [NSMutableString string];
    NSMutableString *vsql = [NSMutableString string];
    NSMutableString *lsql = [NSMutableString string];
    
    for (NSString *key in properties) {
        ZyxFieldAttribute *p = [propertyDict objectForKey:key];
        [psql appendFormat:@"%@, ", p.nameInDB];
        [vsql appendString:@"?, "];
        
        id value = p.isBaseModel ? [model valueForKeyPath:[NSString stringWithFormat:@"%@.id", key]] : [model valueForKey:key];
        [lsql appendFormat:@"%@, ", value];
    }
    
    NSString *sql = @"";
    do {
        if (psql.length == 0) {
            break;
        }
        
        NSString *p = [psql substringToIndex:psql.length-2];
        NSString *v = [vsql substringToIndex:vsql.length-2];
        NSString *l = [lsql substringToIndex:lsql.length-2];
        sql = [NSString stringWithFormat:@"insert into %@ (%@) values (%@)", TABLE_NAME(model), p, v];
        LogInfo(@"makeInsertSQL:\n\t insert into %@ (%@) values (%@)", TABLE_NAME(model), p, l);
        
    } while (FALSE);
    
    return sql;
}

- (BOOL)database:(FMDatabase *)db executeUpdate:(NSString *)sql withArgumentsInArray:(NSArray *)array {
    NSMutableArray *adjustedValues = [NSMutableArray arrayWithCapacity:array.count];
    for (NSUInteger i=0; i<array.count; i++) {
        id value = array[i];
        if ([value isKindOfClass:ZyxBaseModel.class]) {
            id newValue = [value valueForKey:@"id"];
            [adjustedValues addObject:newValue];
        } else {
            [adjustedValues addObject:value];
        }
    }
    return [db executeUpdate:sql withArgumentsInArray:adjustedValues];
}

- (NSString *)makeOrderSQL:(Class)c orders:(NSDictionary *)orders {
    NSArray *orderKeys = orders.allKeys;
    if (orderKeys.count == 0) {
        return @"";
    }
    
    NSDictionary *propertyDict = [c propertiesDictionary];
    
    NSMutableString *orderSql = [NSMutableString stringWithString:@"order by "];
    for (NSString *key in orderKeys) {
        ZyxFieldAttribute *property = [propertyDict objectForKey:key];
        NSString *order = [orders objectForKey:key];
        [orderSql appendFormat:@"%@ %@, ", property.nameInDB, order];
    }
    
    [orderSql setString:[orderSql substringToIndex:orderSql.length - 2]];
    return orderSql;
}

+ (NSString *)dbPathWithSubDirectory:(NSString *)subDirectory {
    NSString *documentDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    NSString* dbDirectory = [documentDir stringByAppendingPathComponent:subDirectory];
    if (![[NSFileManager defaultManager] fileExistsAtPath:dbDirectory]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:dbDirectory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
    }
    NSString *dbPath = [dbDirectory stringByAppendingPathComponent:DBNAME];
    return dbPath;
}

- (NSString *)stringWithMatchType:(int)type {
    switch (type) {
        case DCT_Equal:         return @"=";
        case DCT_NotEqual:      return @"!=";
        case DCT_Like:          return @"like";
        case DCT_Less:          return @"<";
        case DCT_LessEqual:     return @"<=";
        case DCT_Larger:        return @">";
        case DCT_LargerEqual:   return @">=";
        default:
            break;
    }
    return @"=";
}

- (void)checkUpdateSQLResult:(FMDatabase *)db {
    int changes = db.changes;
    if (changes < 1) {
        LogWarning(@"oh no, update sql do not make any changes in db, error code:%d, error message:%@", db.lastErrorCode, db.lastErrorMessage);
    } else {
        LogInfo(@"yes, update sql make effective %d rows", changes);
    }
}

#pragma mark - Interface

- (void)callCapabilityType:(EEasyFMDBCapabilityType)capabilityType withParam:(id)inParam {
    id param = inParam;
    
    NSDictionary *dict = nil;
    id model = nil;
    id block = nil;
    
    if ([param isKindOfClass:NSValue.class]
        || [param isKindOfClass:ZyxBaseModel.class]
        || [param isKindOfClass:NSArray.class]) {
        model = param;
    } else if ([param isKindOfClass:NSDictionary.class]) {
        dict = (NSDictionary *)param;
        model = dict[kEasyFMDBModel];
        block = dict[kEasyFMDBBlock];
    } else {
        LogError(@"oh no, param invalid!");
        return;
    }
    
    switch (capabilityType) {
        case EasyFMDBCapabilityType_Add:
            [self add:model result:block];
            break;
        case EasyFMDBCapabilityType_Update:
            [self update:param result:block];
            break;
        case EasyFMDBCapabilityType_Delete:
            [self delete:param result:block];
            break;
        case EasyFMDBCapabilityType_Query:
            [self query:param result:block];
            break;
    }
}


#pragma mark - Parse Query Param

- (BOOL)parseQueryParam:(NSDictionary *)dict
       propertiesValues:(NSDictionary **)propertiesValues
                matches:(NSArray **)matches
                 logics:(NSArray **)logics
                 orders:(NSDictionary **)orders
                  range:(NSRange *)range {
    if (![dict isKindOfClass:NSDictionary.class]) {
        LogError(@"parseQueryParam1 : param is not a NSDictionary object!");
        return NO;
    }
    
    id mm = dict[kEasyFMDBPropertiesValues];
    if (mm != nil) {
        if ([mm isKindOfClass:NSDictionary.class]) {
            *propertiesValues = mm;
        } else {
            LogError(@"kEasyFMDBPropertiesValues in dict(%@) is not a valid NSDictionary!", dict);
            return NO;
        }
    }
    
    *matches = [self arrayInDictionary:dict forKey:kEasyFMDBMatches];
    *logics = [self arrayInDictionary:dict forKey:kEasyFMDBLogics];
    
    id os = dict[kEasyFMDBOrders];
    if (os == nil || [os isKindOfClass:NSDictionary.class]) {
        *orders = os;
    } else {
        LogWarning(@"kEasyFMDBOrders in dict(%@) is invlalid, so set it to nil", dict);
        *orders = nil;
    }
    
    id r = dict[kEasyFMDBRange];
    if ([r isKindOfClass:NSString.class]) {
        *range = NSRangeFromString(r);
    }
    
    return YES;
}

- (NSArray *)arrayInDictionary:(NSDictionary *)dict forKey:(NSString *)key {
    NSArray *array = nil;
    id value = dict[key];
    if (value != nil) {
        if ([value isKindOfClass:NSArray.class]) {
            array = value;
        } else if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) {
            array = @[value];
        } else {
            LogWarning(@"(%@) in dict(%@) is invlalid, so return nil", key, dict);
        }
    }
    return array;
}

- (NSDictionary *)combineQueryInfoInDictionary:(NSDictionary *)dict ofModel:(ZyxBaseModel *)model {
    id q1 = dict[kEasyFMDBQueryProperties];
    id q2 = dict[kEasyFMDBQueryPropertiesAndValues];
    
    NSMutableDictionary *queries = [[NSMutableDictionary alloc] init];
    if ([q1 isKindOfClass:NSArray.class]) {
        for (NSString *propertyName in q1) {
            queries[propertyName] = [model valueForKey:propertyName];
        }
    } else if ([q1 isKindOfClass:NSString.class]) {
        queries[q1] = [model valueForKey:q1];
    }
    
    if ([q2 isKindOfClass:NSDictionary.class]) {
        [queries addEntriesFromDictionary:q2];
    }
    
    return queries;
}

@end

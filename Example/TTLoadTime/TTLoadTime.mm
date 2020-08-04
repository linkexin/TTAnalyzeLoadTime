//
//  TTLoadTime.m
//  TTLoadTime
//
//  Created by huakucha on 2018/12/13.
//

#import "TTLoadTime.h"
#import <objc/runtime.h>
#import <mach/mach.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#include <mach-o/dyld.h>
#include <mach-o/nlist.h>
#include <mach-o/getsect.h>
#include <string>


@interface TTLoadTime : NSObject
@end

@implementation TTLoadTime


#pragma mark - C++ method list template

template <typename Element, typename List, uint32_t FlagMask>
struct entsize_list_tt {
    uint32_t entsizeAndFlags;
    uint32_t count;
    Element first;
    
    uint32_t entsize() const {
        return entsizeAndFlags & ~FlagMask;
    }
    uint32_t flags() const {
        return entsizeAndFlags & FlagMask;
    }
    
    Element& getOrEnd(uint32_t i) const {
        assert(i <= count);
        return *(Element *)((uint8_t *)&first + i*entsize());
    }
    Element& get(uint32_t i) const {
        assert(i < count);
        return getOrEnd(i);
    }
    
    size_t byteSize() const {
        return sizeof(*this) + (count-1)*entsize();
    }
    
    List *duplicate() const {
        return (List *)memdup(this, this->byteSize());
    }
    
    struct iterator;
    const iterator begin() const {
        return iterator(*static_cast<const List*>(this), 0);
    }
    iterator begin() {
        return iterator(*static_cast<const List*>(this), 0);
    }
    const iterator end() const {
        return iterator(*static_cast<const List*>(this), count);
    }
    iterator end() {
        return iterator(*static_cast<const List*>(this), count);
    }
    
    struct iterator {
        uint32_t entsize;
        uint32_t index;  // keeping track of this saves a divide in operator-
        Element* element;
        
        typedef std::random_access_iterator_tag iterator_category;
        typedef Element value_type;
        typedef ptrdiff_t difference_type;
        typedef Element* pointer;
        typedef Element& reference;
        
        iterator() { }
        
        iterator(const List& list, uint32_t start = 0)
        : entsize(list.entsize())
        , index(start)
        , element(&list.getOrEnd(start))
        { }
        
        const iterator& operator += (ptrdiff_t delta) {
            element = (Element*)((uint8_t *)element + delta*entsize);
            index += (int32_t)delta;
            return *this;
        }
        const iterator& operator -= (ptrdiff_t delta) {
            element = (Element*)((uint8_t *)element - delta*entsize);
            index -= (int32_t)delta;
            return *this;
        }
        const iterator operator + (ptrdiff_t delta) const {
            return iterator(*this) += delta;
        }
        const iterator operator - (ptrdiff_t delta) const {
            return iterator(*this) -= delta;
        }
        
        iterator& operator ++ () { *this += 1; return *this; }
        iterator& operator -- () { *this -= 1; return *this; }
        iterator operator ++ (int) {
            iterator result(*this); *this += 1; return result;
        }
        iterator operator -- (int) {
            iterator result(*this); *this -= 1; return result;
        }
        
        ptrdiff_t operator - (const iterator& rhs) const {
            return (ptrdiff_t)this->index - (ptrdiff_t)rhs.index;
        }
        
        Element& operator * () const { return *element; }
        Element* operator -> () const { return element; }
        
        operator Element& () const { return *element; }
        
        bool operator == (const iterator& rhs) const {
            return this->element == rhs.element;
        }
        bool operator != (const iterator& rhs) const {
            return this->element != rhs.element;
        }
        
        bool operator < (const iterator& rhs) const {
            return this->element < rhs.element;
        }
        bool operator > (const iterator& rhs) const {
            return this->element > rhs.element;
        }
    };
};


struct method_t {
    SEL name;
    const char *types;
    IMP imp;
    
    struct SortBySELAddress :
    public std::binary_function<const method_t&,
    const method_t&, bool>
    {
        bool operator() (const method_t& lhs,
                         const method_t& rhs)
        { return lhs.name < rhs.name; }
    };
};

struct method_list_t : entsize_list_tt<method_t, method_list_t, 0x3> {
};


#pragma mark - Runtime Typedef

typedef struct classref * classref_t;

#ifndef __LP64__
typedef struct mach_header machHeaderType;
#else
typedef struct mach_header_64 machHeaderType;
#endif

struct category_t {
    const char *name;
    classref_t cls;
    void *instanceMethods;
    struct method_list_t *classMethods;
    void *protocols;
    void *instanceProperties;
    void *_classProperties;
    void *methodsForMeta(bool isMeta) {
        if (isMeta) return classMethods;
        else return instanceMethods;
    }
    void *propertiesForMeta(bool isMeta, struct header_info *hi);
};

#define GETSECT(name, type, sectname)                                   \
    type *name(const machHeaderType *mhdr, size_t *outCount) {              \
        return getDataSection<type>(mhdr, sectname, nil, outCount);     \
    }                                                                   \

// __objc_nlclslist: Objective-C 的 +load 函数列表
// __objc_nlcatlist: Objective-C 的 categories 的 +load 函数列表
GETSECT(_getObjc2NonlazyClassList,    classref_t,      "__objc_nlclslist");
GETSECT(_getObjc2NonlazyCategoryList, category_t *,    "__objc_nlcatlist");

template <typename T>
T* getDataSection(const machHeaderType *mhdr, const char *sectname, size_t *outBytes, size_t *outCount) {
    unsigned long byteCount = 0;
    
    T* data = (T*)getsectiondata(mhdr, "__DATA", sectname, &byteCount);
    if (!data) {
        data = (T*)getsectiondata(mhdr, "__DATA_CONST", sectname, &byteCount);
    }
    if (!data) {
        data = (T*)getsectiondata(mhdr, "__DATA_DIRTY", sectname, &byteCount);
    }
    if (outBytes) *outBytes = byteCount;
    if (outCount) *outCount = byteCount / sizeof(T);
    return data;
}


#pragma mark - Static Var Define

static NSMutableArray<NSString*> *g_loadcosts;

static NSMutableDictionary *loadMS;//To record the name of category
static NSMutableDictionary *loadCS;//To void repeat analysis same class

extern "C"{
    category_t **categoryLoadList;
    size_t categoryLoadCount;
}

//  a IMP that returns a value
typedef id (* _IMP) (id, SEL, ...);
// no return value
typedef void (* _VIMP) (id, SEL, ...);


#pragma mark - Static Func Define

const struct mach_header *get_mach_header() {
    const uint32_t imageCount = _dyld_image_count();
    const struct mach_header *mach_header = 0;
    
    for (uint32_t iImg = 0; iImg < imageCount; iImg++) {
        const char *image_name = _dyld_get_image_name(iImg);
        const char *target_image_name = ((NSString *)[[NSBundle mainBundle] objectForInfoDictionaryKey:(NSString*)kCFBundleExecutableKey]).UTF8String;
        // 过滤掉系统的 image，找到和应用匹配的 image
        if (strstr(image_name, target_image_name) != NULL) {
            mach_header = _dyld_get_image_header(iImg);
            break;
        }
    }
    
    return mach_header;
}


#pragma mark - lazy list

category_t **get_non_lazy_category_list(size_t *count) {
    category_t **nlcatlist = NULL;
    // 将 mach header 传入，并从 mach-O 文件的 __DATA 段的特定 Section 中获得 categories 的 +load 函数列表
    nlcatlist = _getObjc2NonlazyCategoryList((machHeaderType *)get_mach_header(), count);
    return nlcatlist;
}

classref_t *get_non_lazy_class_list(size_t *count) {
    classref_t *nlclslist = NULL;
    // 获取 class 的 +load 函数列表
    nlclslist = _getObjc2NonlazyClassList((machHeaderType *)get_mach_header(), count);
    return nlclslist;
}


#pragma mark - Swizze Load

void swizzeLoadMethodInClasss(Class cls, BOOL isCategary) {
    unsigned int methodCount = 0;
    // 获取类的方法列表
    Method *methods = class_copyMethodList(cls, &methodCount);
    for(unsigned int methodIndex = 0; methodIndex < methodCount; ++methodIndex){
        Method method = methods[methodIndex];
        objc_method_description *des = method_getDescription(method);
        std::string methodName(sel_getName(method_getName(method)));
        if (methodName == "load") {
            _VIMP load_IMP = (_VIMP)method_getImplementation(method);
            // hook 的核心方法
            method_setImplementation(method, imp_implementationWithBlock(^(id target, SEL action) {
                CFTimeInterval begin = CACurrentMediaTime();
                // 调用原方法
                load_IMP(target, action);
                
                CFTimeInterval end = CACurrentMediaTime();
                if (!g_loadcosts) {
                    g_loadcosts = [[NSMutableArray alloc] initWithCapacity:10];
                }
                // 将耗时记录到全局的数组中
                NSString *name = [loadMS valueForKey:[NSString stringWithFormat:@"%p",load_IMP]];
                if (name && name.length > 0) {
                    // 如果能从 loadMS 中获取到 name，说明是之前存好的 category 的 name
                } else {
                    // 如果取不到，就说明是 class 的 load 方法，直接取 class 的名字即可
                    name = NSStringFromClass(cls);
                }
                [g_loadcosts addObject:[NSString stringWithFormat:@"%@ - %@ms",name, @(1000 * (end - begin))]];
            }));
            // 这里不能 break，如果这个类的 category 和 class 都有 load 方法，需要都找出来，所以要完整遍历方法列表
        }
    }
}

IMP _category_getLoadMethod(category_t *cat) {
    const method_list_t *mlist;
    mlist = cat->classMethods;
    if (mlist) {
        for (const auto& meth : *mlist) {
            const char *name = (const char *)(void *)(meth.name);
            if (0 == strcmp(name, "load")) {
                return meth.imp;
            }
        }
    }
    return nil;
}


#pragma mark - +Load

+ (void)load {
    // 数据结构初始化
    initializer();
    // 获取所有 category 的 load 函数列表及数目
    categoryLoadList = get_non_lazy_category_list(&categoryLoadCount);
    // 将 category load 的 IMP 及 category 的名字存到全局字典中，后续输出结果时使用
    packageCategoryLoadNameIMPPair();
    // 替换 category 的 load 方法
    swizzeLoadMethodInCategory();
    // 替换 class 的 load 方法
    swizzeLoadMethodInClass();
}


#pragma mark - Helper

void initializer() {
    if (!loadMS) {
        loadMS = [[NSMutableDictionary alloc] init];
    } else {
        [loadMS removeAllObjects];
    }
    
    if (!loadCS) {
        loadCS = [[NSMutableDictionary alloc] init];
    } else {
        [loadCS removeAllObjects];
    }
}

void packageCategoryLoadNameIMPPair() {
    // 这个循环是将 category load 的 IMP 及 category 名字存到 loadMS 中,
    // 做这一步的原因是
    for (int i = 0; i < categoryLoadCount; i++) {
        Class cls = (Class)CFBridgingRelease(categoryLoadList[i]->cls);
        cls = object_getClass(cls); // 注意注意注意，这里要取元类对象，因为 load 是类方法，后续需要到类对象的方法列表中找 +load 方法
        NSString *name = [NSString stringWithCString:categoryLoadList[i]->name encoding:NSUTF8StringEncoding];
        category_t *cat = categoryLoadList[i];
        _VIMP load_IMP = (_VIMP)_category_getLoadMethod(cat);
        [loadMS addEntriesFromDictionary:@{[NSString stringWithFormat:@"%p", load_IMP]: [NSString stringWithFormat:@"%@(%@)", cls, name]}];
    }
}

void swizzeLoadMethodInCategory() {
    for (int i = 0; i < categoryLoadCount; i++) {
        Class cls = (Class)CFBridgingRelease(categoryLoadList[i]->cls);
        cls = object_getClass(cls); // 取元类对象的原因同上
        if (![[loadCS allKeys] containsObject:[NSString stringWithFormat:@"%@", cls]]) {
            swizzeLoadMethodInClasss(cls, YES);
        }
        [loadCS addEntriesFromDictionary:@{[NSString stringWithFormat:@"%@",cls]: cls}];
    }
}

void swizzeLoadMethodInClass() {
    size_t classLoadCount = 0;
    // 获取所有 class 的 load 函数列表及数目
    classref_t *classLoadlist = get_non_lazy_class_list(&classLoadCount);
    
    // ios deployment target 8.0有一个问题 '__ARCLite__'这个Class有点特殊，这个类也实现了load
    //最后一位指向的结构体中isa变量指向0x00000000的指针，故排除
#if __IPHONE_OS_VERSION_MIN_REQUIRED >= 90000
#else
    count--;
#endif

    for (int i = 0; i < classLoadCount; i++) {
        classref_t nlcls = classLoadlist[i];
        Class cls = (__bridge Class)nlcls;
        if ([@"__ARCLite__" isEqualToString:NSStringFromClass(cls)]) {
            continue;
        }
        cls = (Class)CFBridgingRelease(classLoadlist[i]);
        cls = object_getClass(cls); // 取元类对象
            
        if(![[loadCS allKeys] containsObject:NSStringFromClass(cls)]) {
            swizzeLoadMethodInClasss(cls, NO);
        }
    }
}


#pragma mark - Print Results

void printLoadCostsInfo() {
    NSLog(@">> all load cost info below :");
    NSLog(@"\n");
    for (NSString *costInfo in g_loadcosts) {
        NSLog(@"%@",costInfo);
    }
    NSLog(@"\n");
}

@end

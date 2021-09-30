/*
 * Copyright (c) 2004-2007 Apple Inc. All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 * 
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 * 
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 * 
 * @APPLE_LICENSE_HEADER_END@
 */
/*
  Implementation of the weak / associative references for non-GC mode.
*/


#include "objc-private.h"
#include <objc/message.h>
#include <map>
#include "DenseMapExtras.h"

// expanded policy bits.

enum {
    OBJC_ASSOCIATION_SETTER_ASSIGN      = 0,
    OBJC_ASSOCIATION_SETTER_RETAIN      = 1,
    OBJC_ASSOCIATION_SETTER_COPY        = 3,            // NOTE:  both bits are set, so we can simply test 1 bit in releaseValue below.
    OBJC_ASSOCIATION_GETTER_READ        = (0 << 8),
    OBJC_ASSOCIATION_GETTER_RETAIN      = (1 << 8),
    OBJC_ASSOCIATION_GETTER_AUTORELEASE = (2 << 8)
};

spinlock_t AssociationsManagerLock;

namespace objc {

class ObjcAssociation {
    uintptr_t _policy;
    id _value;
public:
    ObjcAssociation(uintptr_t policy, id value) : _policy(policy), _value(value) {}
    ObjcAssociation() : _policy(0), _value(nil) {}
    ObjcAssociation(const ObjcAssociation &other) = default;
    ObjcAssociation &operator=(const ObjcAssociation &other) = default;
    ObjcAssociation(ObjcAssociation &&other) : ObjcAssociation() {
        swap(other);
    }

    inline void swap(ObjcAssociation &other) {
        std::swap(_policy, other._policy);
        std::swap(_value, other._value);
    }

    inline uintptr_t policy() const { return _policy; }
    inline id value() const { return _value; }

    //需要通过_policy进行设置
    //只有两个，copy和retain
    inline void acquireValue() {
        if (_value) {
            switch (_policy & 0xFF) {
            case OBJC_ASSOCIATION_SETTER_RETAIN:
                _value = objc_retain(_value);
                break;
            case OBJC_ASSOCIATION_SETTER_COPY:
                _value = ((id(*)(id, SEL))objc_msgSend)(_value, @selector(copy));
                break;
            }
        }
    }

    inline void releaseHeldValue() {
        if (_value && (_policy & OBJC_ASSOCIATION_SETTER_RETAIN)) {
            objc_release(_value);
        }
    }

    inline void retainReturnedValue() {
        if (_value && (_policy & OBJC_ASSOCIATION_GETTER_RETAIN)) {
            objc_retain(_value);
        }
    }

    //最终取的值是_value
    inline id autoreleaseReturnedValue() {
        if (slowpath(_value && (_policy & OBJC_ASSOCIATION_GETTER_AUTORELEASE))) {
            return objc_autorelease(_value);
        }
        return _value;
    }
};

typedef DenseMap<const void *, ObjcAssociation> ObjectAssociationMap;
typedef DenseMap<DisguisedPtr<objc_object>, ObjectAssociationMap> AssociationsHashMap;

// class AssociationsManager manages a lock / hash table singleton pair.
// Allocating an instance acquires the lock
/*
 管理类管理了一个锁和一个哈希表单例对
 创建一个关联对象将获取到锁
 */

class AssociationsManager {
    using Storage = ExplicitInitDenseMap<DisguisedPtr<objc_object>, ObjectAssociationMap>;
    static Storage _mapStorage;//通过静态变量获取到的，所以是全场唯一的

public:
    //构造函数
    AssociationsManager()   { AssociationsManagerLock.lock(); }
    //析构函数
    ~AssociationsManager()  { AssociationsManagerLock.unlock(); }

    AssociationsHashMap &get() {
        return _mapStorage.get();
    }

    static void init() {
        _mapStorage.init();
    }
};

AssociationsManager::Storage AssociationsManager::_mapStorage;

} // namespace objc

using namespace objc;

void
_objc_associations_init()
{
    AssociationsManager::init();
}

/*
 object是对象，用来查找第一层的值
 key是标识符，用来查找第二层的值
 */
id
_object_get_associative_reference(id object, const void *key)
{
    /*
     这样的做法是为什么？？？？这里把具体的操作放在了一个局部作用域去写，把定义变量和返回值放在外面呢
     */
    
    //定义一个关联对象
    ObjcAssociation association{};
    {
        //拿到全局唯一的哈希map
        AssociationsManager manager;
        AssociationsHashMap &associations(manager.get());
        //迭代器用来循环遍历，这里的迭代器是拿到第一层的桶子
        AssociationsHashMap::iterator i = associations.find((objc_object *)object);
        if (i != associations.end()) {
            //拿到其中的一个ObjectAssociationMap
            ObjectAssociationMap &refs = i->second;
            //拿到这个关联对象map的所有桶子，也就是第二层了
            ObjectAssociationMap::iterator j = refs.find(key);
            if (j != refs.end()) {
                //拿到关联对象
                association = j->second;
                association.retainReturnedValue();//加了个retain
            }
        }
    }

    return association.autoreleaseReturnedValue();//拿到这个值
}

/*
 1、将对象和value值进行初始化
 2、通过管理类拿到关联对象的哈希map表
 3、通过对象查询桶子，如果存在直接返回，如果不存在，则创建一个空桶子并返回
 4、在桶子中通过key查询桶子是否存在，如果存在就更新key-value的键值对。没有就插入。
 */
void
_object_set_associative_reference(id object, const void *key, id value, uintptr_t policy)
{
    // This code used to work when nil was passed for object and key. Some code
    // probably relies on that to not crash. Check and handle it explicitly.
    // rdar://problem/44094390
    if (!object && !value) return;

    if (object->getIsa()->forbidsAssociatedObjects())
        _objc_fatal("objc_setAssociatedObject called on instance (%p) of class %s which does not allow associated objects", object, object_getClassName(object));

    //将objc_object结构体封装成了DisguisedPtr结构体，便于后续使用，作为key值
    DisguisedPtr<objc_object> disguised{(objc_object *)object};
    //将policy和value包装到一个结构体ObjcAssociation中，最为最终存储的value值
    ObjcAssociation association{policy, value};

    // retain the new value (if any) outside the lock.
    //会根据不同的策略进行一下处理，只有retain和copy进行了特殊处理
    association.acquireValue();

    {
        //这个是关联对象的管理类，此处初始化一个对象出来
        /*
         这里的对象不是唯一的，可以创建多个，构造函数和析构函数加锁只是为了多线程
         也就是说每次的使用是唯一的，不可以同时使用多个，只有把上一个删掉之后，才会在析构函数中解锁，
         但是对象本身不是唯一的，是可以创建多个的，使用上只能是当前使用的清掉之后才可以使用下一个
         */
        AssociationsManager manager;//这样写就相当于直接调用了构造函数来创建
        
        /*
         关联对象的HashMap表记录了工程中所有的关联对象，这张表是唯一的，这样做也便于查找
         这里也是通过管理类得到哈希表
         在整个程序中是共享的，因为是通过静态变量获取出来的
         */
        AssociationsHashMap &associations(manager.get());
        /*
         1、hashmap先根据disguised获取到桶子（空桶子或有值的桶子都可以，反正是要获取桶子的）
         2、如果是空桶子，说明是第一次关联对象，就需要设置到isa中
         3、桶子获取到ObjectAssociationMap（关联对象映射）,并将association存入进去，这样就关联到了。
         */
        
        //如果有值，则开始关联，也就是将值保存下来
        if (value) {
            //返回的是一个类对
            /*
             传入的参数
                第一个参数：disguised
                第二个参数：空ObjectAssociationMap
             
             0、他们两个加起来就是一个桶子
             
             1、如果已经存在则直接返回一个桶子
             2、如果不存在则创建一个空桶子并插入进去，也会返回这个空桶子
             3、获取的值中最主要的是一个bucket，也就是说这里的refs_result还有其他数据，包括了桶子
             */
            //将这个结果拿到手，进行解析，发现是一个key-value的键值对
            
            auto refs_result = associations.try_emplace(disguised, ObjectAssociationMap{});
            //返回值就在value中，所以这样获取返回的是一个bool值
            //这个类对，我们需要的是第二个值，所以直接判断second
            //返回值的second就表示是否是空桶子，如果是空的就需要设置isa
            if (refs_result.second) {//判断第二个存不存在，即bool值是否为true
                /* it's the first association we make 如果是第一次建立关联，需要给这个对象设置标记，在isa中*/
                object->setHasAssociatedObjects();//nonpointerIsa ，标记位true
            }

            /* establish or replace the association */
            //创建或替换association
            /*
             所以上面不管获取的是不是空桶子，都不影响这里
             因为如果是空桶子，就创建association，如果不是空桶子，就更新association
             */
            auto &refs = refs_result.first->second;//
            //这里进入的应该是第二个方法，因为key的类型是const void
            auto result = refs.try_emplace(key, std::move(association));//查找当前的key是否有association关联对象
            if (!result.second) {//如果结果不存在
                association.swap(result.first->second);
            }
        //如果传的是空值，则移除关联
        } else {
            auto refs_it = associations.find(disguised);
            if (refs_it != associations.end()) {
                auto &refs = refs_it->second;
                auto it = refs.find(key);
                if (it != refs.end()) {
                    association.swap(it->second);
                    refs.erase(it);
                    if (refs.size() == 0) {
                        associations.erase(refs_it);

                    }
                }
            }
        }
    }

    // release the old value (outside of the lock).
    association.releaseHeldValue();
}

// Unlike setting/getting an associated reference,
// this function is performance sensitive because of
// raw isa objects (such as OS Objects) that can't track
// whether they have associated objects.
void
_object_remove_assocations(id object)
{
    ObjectAssociationMap refs{};

    {
        AssociationsManager manager;
        AssociationsHashMap &associations(manager.get());
        AssociationsHashMap::iterator i = associations.find((objc_object *)object);
        if (i != associations.end()) {
            refs.swap(i->second);
            associations.erase(i);
        }
    }

    // release everything (outside of the lock).
    for (auto &i: refs) {
        i.second.releaseHeldValue();
    }
}

/*
 * Copyright (c) 2004-2006 Apple Inc.  All Rights Reserved.
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

/***********************************************************************
* objc-loadmethod.m
* Support for +load methods.
**********************************************************************/

#include "objc-loadmethod.h"
#include "objc-private.h"

typedef void(*load_method_t)(id, SEL);

struct loadable_class {
    Class cls;  // may be nil
    IMP method;
};

struct loadable_category {
    Category cat;  // may be nil
    IMP method;
};


// List of classes that need +load called (pending superclass +load)
// This list always has superclasses first because of the way it is constructed
static struct loadable_class *loadable_classes = nil;
static int loadable_classes_used = 0;
static int loadable_classes_allocated = 0;

// List of categories that need +load called (pending parent class +load)
static struct loadable_category *loadable_categories = nil;
static int loadable_categories_used = 0;
static int loadable_categories_allocated = 0;


/***********************************************************************
* add_class_to_loadable_list
* Class cls has just become connected. Schedule it for +load if
* it implements a +load method.
 类cls必须是变成可连接的
 如果他实现了一个load方法，就必须列入它到表中
**********************************************************************/
/*
 1、将类、load方法存入到表中，并计数+1
 2、如果容量不足，需要扩容，*2+16
 */
void add_class_to_loadable_list(Class cls)
{
    IMP method;
    loadMethodLock.assertLocked();
    //得到load方法
    method = cls->getLoadMethod();
    if (!method) return;  // Don't bother if cls has no +load method
    
    if (PrintLoading) {
        _objc_inform("LOAD: class '%s' scheduled for +load", 
                     cls->nameForLogging());
    }
    //如果使用的空间等于了开辟的空间，就需要扩容处理。*2+16
    if (loadable_classes_used == loadable_classes_allocated) {
        loadable_classes_allocated = loadable_classes_allocated*2 + 16;
        loadable_classes = (struct loadable_class *)
            realloc(loadable_classes,
                              loadable_classes_allocated *
                              sizeof(struct loadable_class));
    }
    //加入这个类，和方法，并且计数+1
    loadable_classes[loadable_classes_used].cls = cls;//添加类
    loadable_classes[loadable_classes_used].method = method;//添加方法
    loadable_classes_used++;//计数+1
}


/***********************************************************************
* add_category_to_loadable_list
* Category cat's parent class exists and the category has been attached
* to its class. Schedule this category for +load after its parent class
* becomes connected and has its own +load method called.
 1、分类cat的目标类存在，而且分类已经被附着到目标类上，才可以添加
 2、目标类必须是变为可连接的，也就是添加到了类load方法表中，而执行了类的load方法之后才可以保存分类的load方法
 
 上面的条件已经在被调用的方法中进行了处理
 
 具体的处理流程和类load表一样，就不赘述了。
**********************************************************************/
void add_category_to_loadable_list(Category cat)
{
    IMP method;

    loadMethodLock.assertLocked();

    method = _category_getLoadMethod(cat);

    // Don't bother if cat has no +load method
    if (!method) return;

    if (PrintLoading) {
        _objc_inform("LOAD: category '%s(%s)' scheduled for +load", 
                     _category_getClassName(cat), _category_getName(cat));
    }
    
    if (loadable_categories_used == loadable_categories_allocated) {
        loadable_categories_allocated = loadable_categories_allocated*2 + 16;
        loadable_categories = (struct loadable_category *)
            realloc(loadable_categories,
                              loadable_categories_allocated *
                              sizeof(struct loadable_category));
    }

    loadable_categories[loadable_categories_used].cat = cat;
    loadable_categories[loadable_categories_used].method = method;
    loadable_categories_used++;
}


/***********************************************************************
* remove_class_from_loadable_list
* Class cls may have been loadable before, but it is now no longer 
* loadable (because its image is being unmapped). 
**********************************************************************/
void remove_class_from_loadable_list(Class cls)
{
    loadMethodLock.assertLocked();

    if (loadable_classes) {
        int i;
        for (i = 0; i < loadable_classes_used; i++) {
            if (loadable_classes[i].cls == cls) {
                loadable_classes[i].cls = nil;
                if (PrintLoading) {
                    _objc_inform("LOAD: class '%s' unscheduled for +load", 
                                 cls->nameForLogging());
                }
                return;
            }
        }
    }
}


/***********************************************************************
* remove_category_from_loadable_list
* Category cat may have been loadable before, but it is now no longer 
* loadable (because its image is being unmapped). 
**********************************************************************/
void remove_category_from_loadable_list(Category cat)
{
    loadMethodLock.assertLocked();

    if (loadable_categories) {
        int i;
        for (i = 0; i < loadable_categories_used; i++) {
            if (loadable_categories[i].cat == cat) {
                loadable_categories[i].cat = nil;
                if (PrintLoading) {
                    _objc_inform("LOAD: category '%s(%s)' unscheduled for +load",
                                 _category_getClassName(cat), 
                                 _category_getName(cat));
                }
                return;
            }
        }
    }
}


/***********************************************************************
* call_class_loads
* Call all pending class +load methods.
* If new classes become loadable, +load is NOT called for them.
*
* Called only by call_load_methods().
 调用所有的挂起的类的load方法，也就是存放在类load表中的load方法
 如果有新的类变成可以load的状态，他们这些load不会被调用。（这里可能是说还没有被挂起）
**********************************************************************/
static void call_class_loads(void)
{
    int i;
    
    // Detach current loadable list.
    struct loadable_class *classes = loadable_classes;
    int used = loadable_classes_used;
    loadable_classes = nil;
    loadable_classes_allocated = 0;
    loadable_classes_used = 0;
    
    // Call all +loads for the detached list.
    //调用所有的loads
    for (i = 0; i < used; i++) {
        Class cls = classes[i].cls;
        load_method_t load_method = (load_method_t)classes[i].method;
        if (!cls) continue; 

        if (PrintLoading) {
            _objc_inform("LOAD: +[%s load]\n", cls->nameForLogging());
        }
        //调用
        (*load_method)(cls, @selector(load));
    }
    
    // Destroy the detached list.
    if (classes) free(classes);
}


/***********************************************************************
* call_category_loads
* Call some pending category +load methods.
* The parent class of the +load-implementing categories has all of 
*   its categories attached, in case some are lazily waiting for +initalize.
 如果有一个类有了实现load方法的分类，那么此时这个类应当已经附着了所有的分类，以防还有分类正在惰性的等待类的+initalize.
* Don't call +load unless the parent class is connected.
 除非类已连接，否则不要调用+加载。
* If new categories become loadable, +load is NOT called, and they 
*   are added to the end of the loadable list, and we return TRUE.
 如果有新分类是变为可加载的，而且没有调用load方法，而是添加到可加载列表的末尾，然后返回True
* Return FALSE if no new categories became loadable.
* 如果没有新的分类可以变为可加载的，就直接返回true
* Called only by call_load_methods().
**********************************************************************/
/*
 分类的加载搞的这么复杂是想干啥呢：猜测是因会有分类
 */
static bool call_category_loads(void)
{
    int i, shift;
    bool new_categories_added = NO;
    
    // Detach current loadable list.
    struct loadable_category *cats = loadable_categories;
    int used = loadable_categories_used;
    int allocated = loadable_categories_allocated;
    loadable_categories = nil;
    loadable_categories_allocated = 0;
    loadable_categories_used = 0;

    // Call all +loads for the detached list.
    //查询所有的实现了+loads方法的分类并进行判断后删除
    for (i = 0; i < used; i++) {
        Category cat = cats[i].cat;
        load_method_t load_method = (load_method_t)cats[i].method;
        Class cls;
        if (!cat) continue;

        //拿到目标类
        cls = _category_getClass(cat);
        //如果这个类存在且是可加载的
        if (cls  &&  cls->isLoadable()) {
            if (PrintLoading) {
                _objc_inform("LOAD: +[%s(%s) load]\n", 
                             cls->nameForLogging(), 
                             _category_getName(cat));
            }
            //调用
            (*load_method)(cls, @selector(load));
            cats[i].cat = nil;//删除这个分类
        }
    }

    // Compact detached list (order-preserving)
    //压缩列表，因为前面会有删除多个cat，所以这里把删除的位置清掉
    shift = 0;
    for (i = 0; i < used; i++) {
        //如果不是nil就向前走shift个位置
        if (cats[i].cat) {
            //[i-shift]是最新的位置
            //cats[i]是当前要判断的位置
            cats[i-shift] = cats[i];
        }
        //如果是nil，就+1，说明需要前进1位
        else {
            shift++;
        }
    }
    //得到删除后的总数
    used -= shift;

    // Copy any new +load candidates from the new list to the detached list.
    //下面是重新保存一下
    new_categories_added = (loadable_categories_used > 0);
    for (i = 0; i < loadable_categories_used; i++) {
        if (used == allocated) {
            allocated = allocated*2 + 16;
            cats = (struct loadable_category *)
                realloc(cats, allocated *
                                  sizeof(struct loadable_category));
        }
        cats[used++] = loadable_categories[i];
    }

    // Destroy the new list.
    if (loadable_categories) free(loadable_categories);

    // Reattach the (now augmented) detached list. 
    // But if there's nothing left to load, destroy the list.
    //如果没有就初始化
    if (used) {
        loadable_categories = cats;
        loadable_categories_used = used;
        loadable_categories_allocated = allocated;
    } else {
        if (cats) free(cats);
        loadable_categories = nil;
        loadable_categories_used = 0;
        loadable_categories_allocated = 0;
    }

    if (PrintLoading) {
        if (loadable_categories_used != 0) {
            _objc_inform("LOAD: %d categories still waiting for +load\n",
                         loadable_categories_used);
        }
    }

    return new_categories_added;
}


/***********************************************************************
* call_load_methods
* Call all pending class and category +load methods.调用所有待处理的类和分类的load方法
* Class +load methods are called superclass-first. 以父类优先的方式调用load方法
* Category +load methods are not called until after the parent class's +load.在起源类的+load方法之后才会调用分类方法
* 
* This method must be RE-ENTRANT, because a +load could trigger 
* more image mapping. In addition, the superclass-first ordering 
* must be preserved in the face of re-entrant calls. Therefore, 
* only the OUTERMOST call of this function will do anything, and 
* that call will handle all loadable classes, even those generated 
* while it was running.
 
 这个方法必须是可重入的，因为一个laod方法可能会触发更多的镜像文件来加载
 在调用时，必须保留父类的第一顺序，因此只有该函数的最后一层调用的操作才是有效的
 这个调用将处理所有可加载的类，甚至是在运行时生成的类
 
*
* The sequence below preserves +load ordering in the face of 
* image loading during a +load, and make sure that no 
* +load method is forgotten because it was added during 
* a +load call.
 
 下面的顺序是通过load方法时的顺序
 
* Sequence:顺序
* 1. Repeatedly call class +loads until there aren't any more反复调用class +laods,直到没有更多
* 2. Call category +loads ONCE.一次性加载分类+load
* 3. Run more +loads if:在以下情况下运行更多+load
*    (a) there are more classes to load, OR仍然有更多的类要去加载
*    (b) there are some potential category +loads that have 
*        still never been attempted.还有一些潜在的分类没有完成（这里的潜在是指它本身没有load方法，但是和他相同目标类的分类有，也会促使它也去加载）
* Category +loads are only run once to ensure "parent class first"
* ordering, even if a category +load triggers a new loadable class
* and a new loadable category attached to that class. 
*
 分类只能运行一次，以确保起源类优先的顺序，因为还有分类促使了一个新可加载类，新的可加载分类附着到这个类上
* Locking: loadMethodLock must be held by the caller 
*   All other locks must not be held.
**********************************************************************/

/*
 上面那些话说了这么几个事情：
 1、起源类优先加载，分类后加载
 2、越是最后加载的分类越是有效的，因为覆盖掉了
 3、先把所有的起源类调用一遍，之后查询所有有load方法的分类，
 */
void call_load_methods(void)
{
    static bool loading = NO;
    bool more_categories;

    loadMethodLock.assertLocked();

    // Re-entrant calls do nothing; the outermost call will finish the job.
    if (loading) return;
    loading = YES;

    void *pool = objc_autoreleasePoolPush();

    do {
        // 1. Repeatedly call class +loads until there aren't any more
        //先循环执行所有的类load表中的load方法
        while (loadable_classes_used > 0) {
            call_class_loads();
        }

        // 2. Call category +loads ONCE
        //之后再执行分类的方法
        more_categories = call_category_loads();

        // 3. Run more +loads if there are classes OR more untried categories
        //如果还有类并且还有没有尝试的分类，就继续执行
    } while (loadable_classes_used > 0  ||  more_categories);

    objc_autoreleasePoolPop(pool);

    loading = NO;
}



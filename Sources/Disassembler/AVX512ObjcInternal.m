#import "AVX512ObjcInternal.h"
#import <objc/runtime.h>
#import <stdlib.h>

NSArray<Class> *AVX512GetAllSubclasses(Class cls, BOOL includeClass) {
    if (cls == Nil) { return @[]; }

    unsigned int classCount = objc_getClassList(NULL, 0);
    if (classCount == 0) { return @[]; }

    size_t allocationSize = sizeof(Class) * (size_t)classCount;
    Class *classes = (Class *)malloc(allocationSize);
    if (classes == NULL) { return @[]; }

    classCount = objc_getClassList(classes, classCount);

    NSMutableArray<Class> *result = [NSMutableArray array];
    for (unsigned int i = 0; i < classCount; i++) {
        Class candidate = classes[i];
        if (!includeClass && candidate == cls) { continue; }

        Class superclass = class_getSuperclass(candidate);
        while (superclass != Nil) {
            if (superclass == cls) {
                [result addObject:candidate];
                break;
            }
            superclass = class_getSuperclass(superclass);
        }
    }

    free(classes);
    return result.copy;
}

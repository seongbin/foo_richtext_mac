#import "stdafx.h"
#import "notify.h"

namespace {
    NSHashTable<id<RTRefreshListener>> * listeners() {
        static NSHashTable<id<RTRefreshListener>> * t = [NSHashTable weakObjectsHashTable];
        return t;
    }
}

void rt_add_listener(id<RTRefreshListener> listener) { [listeners() addObject:listener]; }
void rt_remove_listener(id<RTRefreshListener> listener) { [listeners() removeObject:listener]; }
void rt_notify_refresh() {
    for ( id<RTRefreshListener> l in listeners().allObjects ) [l rtRefresh];
}

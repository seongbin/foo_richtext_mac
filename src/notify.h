#import "stdafx.h"

@protocol RTRefreshListener <NSObject>
- (void)rtRefresh;
@end

// Weak-ref registry of views that should re-render on playback/config changes.
void rt_add_listener(id<RTRefreshListener> listener);
void rt_remove_listener(id<RTRefreshListener> listener);
void rt_notify_refresh();

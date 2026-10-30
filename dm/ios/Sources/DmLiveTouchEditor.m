// A passthrough child overlay: the production pad owns every editable control.
#import "DmLiveTouchEditor.h"
#import "DmGamepad.h"
#include <math.h>

@interface DmLivePassthroughView : UIView
@end
@implementation DmLivePassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}
@end

@implementation DmLiveTouchEditor {
    __weak UIView *_pad;
    UIView *_toolbar;
    UIVisualEffectView *_material;
    UIScrollView *_topRow;
    UIScrollView *_menuRow;
    UIButton *_handle;
    UIButton *_reset;
    UIButton *_cancel;
    UIButton *_save;
    UIButton *_control;
    UIButton *_parameter;
    UISlider *_slider;
    UILabel *_value;
    NSString *_parameterKey;
    CGRect _rootBounds;
    CGRect _preferredRegion;
    CGRect _usableBounds;
    UIEdgeInsets _safeInsets;
    CGPoint _dragOrigin;
    CGPoint _normalizedCenter;
    BOOL _hasLayout;
    BOOL _userMoved;
}

static NSString *live_profile_title(NSString *profile) {
    if ([profile isEqualToString:@"inner"]) return @"内屏布局";
    if ([profile isEqualToString:@"folded"]) return @"双区布局";
    return @"外屏布局";
}

static NSString *live_control_title(NSString *control) {
    if ([control isEqualToString:@"LEFT_STICK"]) return @"左摇杆";
    if ([control isEqualToString:@"RIGHT_STICK"]) return @"右摇杆";
    if ([control isEqualToString:@"DPAD"]) return @"方向键";
    if ([control isEqualToString:@"MINUS"]) return @"－ 键";
    if ([control isEqualToString:@"PLUS"]) return @"＋ 键";
    return control.length ? [control stringByAppendingString:@" 键"] : @"未选择";
}

static NSArray<NSDictionary<NSString *, id> *> *live_parameters(void) {
    return @[
        @{@"key": @"scale", @"title": @"大小", @"label": @"控件大小", @"min": @.5, @"max": @1.8, @"step": @.05, @"default": @1, @"percent": @YES},
        @{@"key": @"opacity", @"title": @"不透明度", @"label": @"按键不透明度", @"min": @.2, @"max": @1, @"step": @.05, @"default": @.75, @"percent": @YES},
        @{@"key": @"leftSensitivity", @"title": @"左灵敏度", @"label": @"左摇杆灵敏度", @"min": @.25, @"max": @2.5, @"step": @.05, @"default": @1, @"percent": @NO},
        @{@"key": @"leftDeadZone", @"title": @"左死区", @"label": @"左摇杆死区", @"min": @0, @"max": @.4, @"step": @.01, @"default": @.1, @"percent": @YES},
        @{@"key": @"rightSensitivity", @"title": @"右灵敏度", @"label": @"右摇杆灵敏度", @"min": @.25, @"max": @2.5, @"step": @.05, @"default": @1, @"percent": @NO},
        @{@"key": @"rightDeadZone", @"title": @"右死区", @"label": @"右摇杆死区", @"min": @0, @"max": @.4, @"step": @.01, @"default": @.1, @"percent": @YES},
    ];
}

static UIButton *live_button(NSString *title, NSString *identifier) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = .75;
    button.accessibilityIdentifier = [@"live.layout." stringByAppendingString:identifier];
    return button;
}

static CGRect live_safe_rect(CGRect bounds, UIEdgeInsets insets) {
    if (CGRectIsNull(bounds) || CGRectIsInfinite(bounds) || CGRectIsEmpty(bounds)) return CGRectZero;
    CGFloat width = bounds.size.width, height = bounds.size.height;
    CGFloat left = isfinite(insets.left) ? MIN(width, MAX(0, insets.left)) : 0;
    CGFloat right = isfinite(insets.right) ? MIN(width - left, MAX(0, insets.right)) : 0;
    CGFloat top = isfinite(insets.top) ? MIN(height, MAX(0, insets.top)) : 0;
    CGFloat bottom = isfinite(insets.bottom) ? MIN(height - top, MAX(0, insets.bottom)) : 0;
    return CGRectMake(bounds.origin.x + left, bounds.origin.y + top, width - left - right, height - top - bottom);
}

- (instancetype)initWithPad:(UIView *)pad {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _pad = pad;
        _parameterKey = @"scale";
        _preferredRegion = CGRectNull;
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    return self;
}

- (void)loadView {
    self.view = [DmLivePassthroughView new];
    self.view.backgroundColor = UIColor.clearColor;
    self.view.opaque = NO;
    self.view.accessibilityViewIsModal = NO;
    self.view.accessibilityIdentifier = @"live.layout.overlay";
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _toolbar = [UIView new];
    _toolbar.layer.cornerRadius = 16;
    _toolbar.clipsToBounds = YES;
    _toolbar.layer.borderWidth = 1;
    _toolbar.layer.borderColor = [UIColor colorWithWhite:1 alpha:.2].CGColor;
    _toolbar.accessibilityIdentifier = @"live.layout.toolbar";
    [self.view addSubview:_toolbar];
    _material = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
    _material.userInteractionEnabled = NO;
    [_toolbar addSubview:_material];

    _topRow = [UIScrollView new];
    _topRow.showsHorizontalScrollIndicator = NO;
    _topRow.delaysContentTouches = NO;
    [_toolbar addSubview:_topRow];
    _handle = live_button(@"≡ 布局", @"handle");
    _handle.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    _handle.accessibilityHint = @"拖动工具条，避免遮挡按键";
    UIPanGestureRecognizer *drag = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragToolbar:)];
    drag.maximumNumberOfTouches = 1;
    [_handle addGestureRecognizer:drag];
    [_topRow.panGestureRecognizer requireGestureRecognizerToFail:drag];
    [_topRow addSubview:_handle];
    _reset = live_button(@"重置", @"reset");
    [_reset addTarget:self action:@selector(resetDraft) forControlEvents:UIControlEventTouchUpInside];
    [_topRow addSubview:_reset];
    _cancel = live_button(@"取消", @"cancel");
    [_cancel addTarget:self action:@selector(cancelDraft) forControlEvents:UIControlEventTouchUpInside];
    [_topRow addSubview:_cancel];
    _save = live_button(@"保存", @"save");
    [_save setTitleColor:UIColor.systemOrangeColor forState:UIControlStateNormal];
    [_save addTarget:self action:@selector(saveDraft) forControlEvents:UIControlEventTouchUpInside];
    [_topRow addSubview:_save];

    _menuRow = [UIScrollView new];
    _menuRow.showsHorizontalScrollIndicator = NO;
    _menuRow.delaysContentTouches = NO;
    [_toolbar addSubview:_menuRow];
    _control = live_button(@"选择控件 ▾", @"control");
    _control.showsMenuAsPrimaryAction = YES;
    _control.titleLabel.numberOfLines = 2;
    _control.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    [_menuRow addSubview:_control];
    _parameter = live_button(@"大小 ▾", @"parameter");
    _parameter.showsMenuAsPrimaryAction = YES;
    _parameter.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    [_menuRow addSubview:_parameter];
    _slider = [UISlider new];
    _slider.continuous = YES;
    _slider.accessibilityIdentifier = @"live.layout.slider";
    [_slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [_toolbar addSubview:_slider];
    _value = [UILabel new];
    _value.textColor = UIColor.labelColor;
    _value.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
    _value.textAlignment = NSTextAlignmentRight;
    _value.adjustsFontSizeToFitWidth = YES;
    _value.minimumScaleFactor = .7;
    _value.accessibilityIdentifier = @"live.layout.value";
    [_toolbar addSubview:_value];

    __weak DmLiveTouchEditor *weakSelf = self;
    if (_pad) dm_gamepad_editor_on_selection(_pad, ^(NSString *selection) {
        (void)selection;
        [weakSelf refresh];
    });
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(editingChanged:)
        name:DmGamepadLayoutEditingDidChangeNotification object:_pad];
    [self refresh];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (NSDictionary *)parameterSpec {
    for (NSDictionary *spec in live_parameters()) if ([spec[@"key"] isEqualToString:_parameterKey]) return spec;
    return live_parameters().firstObject;
}

- (void)refresh {
    if (!self.isViewLoaded) return;
    UIView *pad = _pad;
    BOOL editing = pad && dm_gamepad_is_layout_editing(pad);
    NSArray<NSString *> *controls = editing ? dm_gamepad_layout_edit_controls(pad) : @[];
    NSString *selection = editing ? dm_gamepad_editor_selection(pad) : @"";
    NSDictionary *settings = editing ? dm_gamepad_editor_settings(pad) : @{};
    NSString *profile = editing ? dm_gamepad_layout_edit_profile(pad) : @"outer";
    [_handle setTitle:[@"≡ " stringByAppendingString:live_profile_title(profile)] forState:UIControlStateNormal];
    _reset.enabled = _cancel.enabled = _save.enabled = editing;
    _control.enabled = editing && controls.count != 0;
    [_control setTitle:controls.count ? [live_control_title(selection) stringByAppendingString:@" ▾"] : @"当前为触屏布局，\n没有可移动控件" forState:UIControlStateNormal];
    _control.accessibilityLabel = controls.count ? @"选择布局控件" : @"当前为触屏布局，没有可移动控件";
    __weak DmLiveTouchEditor *weakSelf = self;
    NSMutableArray<UIMenuElement *> *controlActions = [NSMutableArray array];
    for (NSString *control in controls) {
        UIAction *action = [UIAction actionWithTitle:live_control_title(control) image:nil
            identifier:[@"live.layout.control." stringByAppendingString:control] handler:^(__kindof UIAction *a) {
                (void)a; [weakSelf selectControl:control];
            }];
        action.state = [control isEqualToString:selection] ? UIMenuElementStateOn : UIMenuElementStateOff;
        [controlActions addObject:action];
    }
    _control.menu = [UIMenu menuWithTitle:@"选择控件" children:controlActions];
    NSMutableArray<UIMenuElement *> *parameterActions = [NSMutableArray array];
    for (NSDictionary *spec in live_parameters()) {
        NSString *key = spec[@"key"];
        UIAction *action = [UIAction actionWithTitle:spec[@"label"] image:nil
            identifier:[@"live.layout.parameter." stringByAppendingString:key] handler:^(__kindof UIAction *a) {
                (void)a; [weakSelf selectParameter:key];
            }];
        action.state = [key isEqualToString:_parameterKey] ? UIMenuElementStateOn : UIMenuElementStateOff;
        if ([key isEqualToString:@"scale"] && controls.count == 0) action.attributes = UIMenuElementAttributesDisabled;
        [parameterActions addObject:action];
    }
    _parameter.menu = [UIMenu menuWithTitle:@"调整参数" children:parameterActions];
    _parameter.enabled = editing;
    NSDictionary *spec = self.parameterSpec;
    [_parameter setTitle:[spec[@"title"] stringByAppendingString:@" ▾"] forState:UIControlStateNormal];
    BOOL size = [_parameterKey isEqualToString:@"scale"];
    NSNumber *value = size ? settings[@"controls"][selection][@"scale"] : settings[_parameterKey];
    double current = [value isKindOfClass:NSNumber.class] ? value.doubleValue : [spec[@"default"] doubleValue];
    if (!isfinite(current)) current = [spec[@"default"] doubleValue];
    _slider.minimumValue = [spec[@"min"] floatValue];
    _slider.maximumValue = [spec[@"max"] floatValue];
    _slider.value = (float)current;
    _slider.enabled = editing && (!size || [controls containsObject:selection]);
    _slider.accessibilityLabel = size ? [live_control_title(selection) stringByAppendingString:@"大小"] : spec[@"label"];
    _value.text = size && controls.count == 0 ? @"—" : [spec[@"percent"] boolValue]
        ? [NSString stringWithFormat:@"%.0f%%", current * 100] : [NSString stringWithFormat:@"%.2f 倍", current];
}

- (void)selectControl:(NSString *)control {
    UIView *pad = _pad;
    if (!pad || !dm_gamepad_is_layout_editing(pad) || ![dm_gamepad_layout_edit_controls(pad) containsObject:control]) return;
    dm_gamepad_editor_select(pad, control);
    [self refresh];
}

- (void)selectParameter:(NSString *)key {
    for (NSDictionary *spec in live_parameters()) if ([spec[@"key"] isEqualToString:key]) { _parameterKey = [key copy]; break; }
    NSString *stick = [key hasPrefix:@"left"] ? @"LEFT_STICK" : [key hasPrefix:@"right"] ? @"RIGHT_STICK" : nil;
    if (stick && _pad && [dm_gamepad_layout_edit_controls(_pad) containsObject:stick])
        dm_gamepad_editor_select(_pad, stick);
    [self refresh];
}

- (void)sliderChanged:(UISlider *)slider {
    UIView *pad = _pad;
    if (!pad || !dm_gamepad_is_layout_editing(pad)) return;
    NSDictionary *spec = self.parameterSpec;
    double step = [spec[@"step"] doubleValue];
    double value = round(slider.value / step) * step;
    value = fmin(fmax(value, [spec[@"min"] doubleValue]), [spec[@"max"] doubleValue]);
    if ([_parameterKey isEqualToString:@"scale"]) {
        if (![dm_gamepad_layout_edit_controls(pad) containsObject:dm_gamepad_editor_selection(pad)]) return;
        dm_gamepad_editor_set_scale(pad, value);
    } else dm_gamepad_update_layout_draft(pad, @{_parameterKey: @(value)});
    [self refresh];
}

- (void)resetDraft { if (_pad && dm_gamepad_is_layout_editing(_pad)) { dm_gamepad_reset_layout_draft(_pad); [self refresh]; } }
- (void)cancelDraft { UIView *pad = _pad; if (pad) dm_gamepad_end_layout_edit(pad, NO); }
- (void)saveDraft { UIView *pad = _pad; if (pad) dm_gamepad_end_layout_edit(pad, YES); }
- (void)editingChanged:(NSNotification *)notification { (void)notification; [self refresh]; }

- (void)layoutInBounds:(CGRect)bounds safeInsets:(UIEdgeInsets)insets preferredRegion:(CGRect)region {
    _rootBounds = bounds; _safeInsets = insets; _preferredRegion = region; _hasLayout = YES;
    [self loadViewIfNeeded];
    [self placeToolbar];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!_hasLayout) { _rootBounds = self.view.bounds; _safeInsets = self.view.safeAreaInsets; }
    [self placeToolbar];
}

- (CGPoint)clampedToolbarCenter:(CGPoint)center {
    CGFloat x = _toolbar.bounds.size.width / 2, y = _toolbar.bounds.size.height / 2;
    return CGPointMake(MIN(MAX(center.x, CGRectGetMinX(_usableBounds) + x), CGRectGetMaxX(_usableBounds) - x),
                       MIN(MAX(center.y, CGRectGetMinY(_usableBounds) + y), CGRectGetMaxY(_usableBounds) - y));
}

- (void)placeToolbar {
    if (!_toolbar) return;
    CGRect safe = live_safe_rect(_rootBounds, _safeInsets);
    if (CGRectIsEmpty(safe)) { _toolbar.hidden = YES; return; }
    _toolbar.hidden = NO;
    _usableBounds = safe;
    CGRect region = CGRectIntersection(safe, _preferredRegion);
    if (CGRectIsEmpty(region) || CGRectIsNull(region) || CGRectIsInfinite(region)) region = safe;
    CGFloat width = MIN(safe.size.width, MIN(360, MAX(160, region.size.width - 16)));
    CGFloat height = MIN(132, safe.size.height);
    _toolbar.bounds = CGRectMake(0, 0, width, height);
    CGPoint center = _userMoved ? CGPointMake(safe.origin.x + _normalizedCenter.x * safe.size.width,
                                             safe.origin.y + _normalizedCenter.y * safe.size.height)
                               : CGPointMake(CGRectGetMidX(region), CGRectGetMidY(region));
    _toolbar.center = [self clampedToolbarCenter:center];
    _material.frame = _toolbar.bounds;
    CGFloat available = MAX(0, width - 16);
    _topRow.frame = CGRectMake(8, 5, available, 36);
    CGFloat topWidth = MAX(272, available);
    _topRow.contentSize = CGSizeMake(topWidth, 36);
    _handle.frame = CGRectMake(0, 0, topWidth - 156, 36);
    _reset.frame = CGRectMake(topWidth - 152, 0, 48, 36);
    _cancel.frame = CGRectMake(topWidth - 100, 0, 48, 36);
    _save.frame = CGRectMake(topWidth - 48, 0, 48, 36);
    _menuRow.frame = CGRectMake(8, 45, available, 34);
    CGFloat menuWidth = MAX(240, available);
    _menuRow.contentSize = CGSizeMake(menuWidth, 34);
    _control.frame = CGRectMake(0, 0, menuWidth / 2 - 4, 34);
    _parameter.frame = CGRectMake(menuWidth / 2 + 4, 0, menuWidth / 2 - 4, 34);
    _slider.frame = CGRectMake(10, 86, MAX(0, width - 90), 36);
    _value.frame = CGRectMake(MAX(0, width - 72), 86, 62, 36);
}

- (void)dragToolbar:(UIPanGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) _dragOrigin = _toolbar.center;
    if (gesture.state == UIGestureRecognizerStateBegan || gesture.state == UIGestureRecognizerStateChanged) {
        CGPoint translation = [gesture translationInView:self.view];
        CGPoint center = [self clampedToolbarCenter:CGPointMake(_dragOrigin.x + translation.x, _dragOrigin.y + translation.y)];
        _toolbar.center = center;
        _userMoved = YES;
        _normalizedCenter = CGPointMake((center.x - _usableBounds.origin.x) / MAX(1, _usableBounds.size.width),
                                        (center.y - _usableBounds.origin.y) / MAX(1, _usableBounds.size.height));
    }
}
@end

// A passthrough child overlay: the production pad owns every editable control.
#import "DmLiveTouchEditor.h"
#import "DmGamepad.h"
#import "DmReflectionPreferences.h"
#import "DmControlReflection.h"
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
    DmReflectionPreferences *_reflectionPreferences;
    UISegmentedControl *_tabs;
    UIScrollView *_reflectionSwitchRow, *_reflectionMenuRow;
    UIButton *_reflectionEnabled, *_reflectionAngleLinked, *_reflectionParameter, *_reflectionCurve;
    UISlider *_reflectionSlider;
    UILabel *_reflectionValue, *_reflectionTip;
    NSString *_reflectionParameterKey;
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
    if ([profile isEqualToString:@"inner"]) return @"内屏横屏布局";
    if ([profile isEqualToString:@"folded"]) return @"内屏竖屏布局";
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

static NSArray<NSDictionary<NSString *, id> *> *reflection_parameters(void) {
    return @[
        @{@"key": @"brightness", @"title": @"亮度", @"min": @0, @"max": @1, @"step": @.05, @"default": @1, @"unit": @"percent"},
        @{@"key": @"length", @"title": @"长度", @"min": @.25, @"max": @3, @"step": @.05, @"default": @1, @"unit": @"multiple"},
        @{@"key": @"blur", @"title": @"模糊", @"min": @0, @"max": @1, @"step": @.05, @"default": @1, @"unit": @"percent"},
        @{@"key": @"feather", @"title": @"边缘柔化", @"min": @0, @"max": @40, @"step": @1, @"default": @12, @"unit": @"points"},
    ];
}

static NSString *reflection_curve_title(NSString *curve) {
    if ([curve isEqualToString:@"linear"]) return @"线性";
    if ([curve isEqualToString:@"smooth"]) return @"平滑";
    return @"贝塞尔";
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
    return [self initWithPad:pad reflectionPreferences:nil];
}
- (instancetype)initWithPad:(UIView *)pad reflectionPreferences:(DmReflectionPreferences *)preferences {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _pad = pad;
        _reflectionPreferences = preferences;
        _parameterKey = @"scale";
        _reflectionParameterKey = @"brightness";
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

    if (_reflectionPreferences) [self makeReflectionControls];

    __weak DmLiveTouchEditor *weakSelf = self;
    if (_pad) dm_gamepad_editor_on_selection(_pad, ^(NSString *selection) {
        (void)selection;
        [weakSelf refresh];
    });
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(editingChanged:)
        name:DmGamepadLayoutEditingDidChangeNotification object:_pad];
    if (_reflectionPreferences)
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reflectionChanged:)
            name:DmControlReflectionDidChangeNotification object:nil];
    [self refresh];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)makeReflectionControls {
    _tabs = [[UISegmentedControl alloc] initWithItems:@[@"按键", @"倒影"]];
    _tabs.selectedSegmentIndex = 0; _tabs.accessibilityIdentifier = @"live.layout.tabs";
    [_tabs addTarget:self action:@selector(tabChanged:) forControlEvents:UIControlEventValueChanged];
    [_toolbar addSubview:_tabs];
    _reflectionSwitchRow = [UIScrollView new];
    _reflectionSwitchRow.showsHorizontalScrollIndicator = NO; _reflectionSwitchRow.delaysContentTouches = NO;
    [_toolbar addSubview:_reflectionSwitchRow];
    _reflectionEnabled = live_button(@"倒影：开", @"reflection.enabled");
    _reflectionEnabled.accessibilityIdentifier = @"live.reflection.enabled";
    _reflectionEnabled.accessibilityLabel = @"倒影开关";
    [_reflectionEnabled addTarget:self action:@selector(toggleReflectionEnabled) forControlEvents:UIControlEventTouchUpInside];
    [_reflectionSwitchRow addSubview:_reflectionEnabled];
    _reflectionAngleLinked = live_button(@"角度联动：开", @"reflection.angleLinked");
    _reflectionAngleLinked.accessibilityIdentifier = @"live.reflection.angleLinked";
    _reflectionAngleLinked.accessibilityLabel = @"角度联动";
    [_reflectionAngleLinked addTarget:self action:@selector(toggleReflectionAngleLinked) forControlEvents:UIControlEventTouchUpInside];
    [_reflectionSwitchRow addSubview:_reflectionAngleLinked];

    _reflectionMenuRow = [UIScrollView new];
    _reflectionMenuRow.showsHorizontalScrollIndicator = NO; _reflectionMenuRow.delaysContentTouches = NO;
    [_toolbar addSubview:_reflectionMenuRow];
    _reflectionParameter = live_button(@"亮度 ▾", @"reflection.parameter");
    _reflectionParameter.accessibilityIdentifier = @"live.reflection.parameter";
    _reflectionParameter.showsMenuAsPrimaryAction = YES;
    _reflectionParameter.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    [_reflectionMenuRow addSubview:_reflectionParameter];
    _reflectionCurve = live_button(@"曲线：贝塞尔 ▾", @"reflection.curve");
    _reflectionCurve.accessibilityIdentifier = @"live.reflection.curve";
    _reflectionCurve.showsMenuAsPrimaryAction = YES;
    _reflectionCurve.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    [_reflectionMenuRow addSubview:_reflectionCurve];
    _reflectionSlider = [UISlider new]; _reflectionSlider.continuous = YES;
    _reflectionSlider.accessibilityIdentifier = @"live.reflection.slider";
    [_reflectionSlider addTarget:self action:@selector(reflectionSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [_toolbar addSubview:_reflectionSlider];
    _reflectionValue = [UILabel new];
    _reflectionValue.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
    _reflectionValue.textColor = UIColor.labelColor; _reflectionValue.textAlignment = NSTextAlignmentRight;
    _reflectionValue.adjustsFontSizeToFitWidth = YES; _reflectionValue.minimumScaleFactor = .7;
    _reflectionValue.accessibilityIdentifier = @"live.reflection.value";
    [_toolbar addSubview:_reflectionValue];
    _reflectionTip = [UILabel new];
    _reflectionTip.text = @"仅内屏竖屏弯折时预览。\n本游戏共用，不更改按键布局。";
    _reflectionTip.font = [UIFont systemFontOfSize:11]; _reflectionTip.textColor = UIColor.secondaryLabelColor;
    _reflectionTip.numberOfLines = 2; _reflectionTip.adjustsFontSizeToFitWidth = YES;
    _reflectionTip.minimumScaleFactor = .7; _reflectionTip.accessibilityIdentifier = @"live.reflection.tip";
    [_toolbar addSubview:_reflectionTip];
}

- (BOOL)reflectionTab { return _reflectionPreferences != nil && _tabs.selectedSegmentIndex == 1; }
- (BOOL)reflectionEditable {
    return _pad && dm_gamepad_is_layout_editing(_pad) && _reflectionPreferences.editing;
}
- (NSDictionary *)reflectionParameterSpec {
    for (NSDictionary *spec in reflection_parameters())
        if ([spec[@"key"] isEqualToString:_reflectionParameterKey]) return spec;
    return reflection_parameters().firstObject;
}
- (void)selectTab:(NSInteger)index {
    if (!_reflectionPreferences || (index != 0 && index != 1)) return;
    [self loadViewIfNeeded]; _tabs.selectedSegmentIndex = index;
    [self refresh]; [self placeToolbar];
}
- (void)tabChanged:(UISegmentedControl *)tabs { [self selectTab:tabs.selectedSegmentIndex]; }
- (void)reflectionChanged:(NSNotification *)notification {
    (void)notification;
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; }); return; }
    [self refresh];
}

- (void)refreshReflectionControls {
    if (!_reflectionPreferences) return;
    BOOL selected = self.reflectionTab, editable = self.reflectionEditable;
    _menuRow.hidden = _slider.hidden = _value.hidden = selected;
    _reflectionSwitchRow.hidden = _reflectionMenuRow.hidden = _reflectionSlider.hidden =
        _reflectionValue.hidden = _reflectionTip.hidden = !selected;
    _tabs.enabled = _pad && dm_gamepad_is_layout_editing(_pad);
    NSDictionary *settings = _reflectionPreferences.currentSettings;
    BOOL enabled = [settings[@"enabled"] boolValue], linked = [settings[@"angleLinked"] boolValue];
    [_reflectionEnabled setTitle:enabled ? @"倒影：开" : @"倒影：关" forState:UIControlStateNormal];
    [_reflectionAngleLinked setTitle:linked ? @"角度联动：开" : @"角度联动：关" forState:UIControlStateNormal];
    _reflectionEnabled.selected = enabled; _reflectionAngleLinked.selected = linked;
    _reflectionEnabled.accessibilityValue = enabled ? @"开" : @"关";
    _reflectionAngleLinked.accessibilityValue = linked ? @"开" : @"关";
    _reflectionEnabled.enabled = _reflectionAngleLinked.enabled = editable;
    _reflectionParameter.enabled = _reflectionCurve.enabled = _reflectionSlider.enabled = editable;
    __weak DmLiveTouchEditor *weakSelf = self;
    NSMutableArray<UIMenuElement *> *parameters = [NSMutableArray array];
    for (NSDictionary *spec in reflection_parameters()) {
        NSString *key = spec[@"key"];
        UIAction *action = [UIAction actionWithTitle:spec[@"title"] image:nil
            identifier:[@"live.reflection.parameter." stringByAppendingString:key] handler:^(__kindof UIAction *item) {
                (void)item; [weakSelf selectReflectionParameter:key];
            }];
        action.state = [key isEqualToString:_reflectionParameterKey] ? UIMenuElementStateOn : UIMenuElementStateOff;
        [parameters addObject:action];
    }
    _reflectionParameter.menu = [UIMenu menuWithTitle:@"倒影参数" children:parameters];
    NSDictionary *spec = self.reflectionParameterSpec;
    [_reflectionParameter setTitle:[spec[@"title"] stringByAppendingString:@" ▾"] forState:UIControlStateNormal];
    double value = [settings[_reflectionParameterKey] doubleValue];
    _reflectionSlider.minimumValue = [spec[@"min"] floatValue];
    _reflectionSlider.maximumValue = [spec[@"max"] floatValue]; _reflectionSlider.value = (float)value;
    _reflectionSlider.accessibilityLabel = [@"倒影" stringByAppendingString:spec[@"title"]];
    NSString *unit = spec[@"unit"];
    _reflectionValue.text = [unit isEqualToString:@"percent"] ? [NSString stringWithFormat:@"%.0f%%", value * 100]
        : [unit isEqualToString:@"points"] ? [NSString stringWithFormat:@"%.0f 点", value]
        : [NSString stringWithFormat:@"%.2f 倍", value];
    NSMutableArray<UIMenuElement *> *curves = [NSMutableArray array];
    for (NSString *curve in @[@"linear", @"smooth", @"bezier"]) {
        UIAction *action = [UIAction actionWithTitle:reflection_curve_title(curve) image:nil
            identifier:[@"live.reflection.curve." stringByAppendingString:curve] handler:^(__kindof UIAction *item) {
                (void)item; [weakSelf selectReflectionCurve:curve];
            }];
        action.state = [curve isEqualToString:settings[@"curve"]] ? UIMenuElementStateOn : UIMenuElementStateOff;
        [curves addObject:action];
    }
    _reflectionCurve.menu = [UIMenu menuWithTitle:@"衰减曲线" children:curves];
    [_reflectionCurve setTitle:[NSString stringWithFormat:@"曲线：%@ ▾", reflection_curve_title(settings[@"curve"])] forState:UIControlStateNormal];
    if (selected) {
        [_handle setTitle:@"≡ 倒影参数" forState:UIControlStateNormal];
        _reset.enabled = editable;
    }
    _reset.accessibilityLabel = selected ? @"重置倒影参数" : @"重置当前按键布局";
}

- (void)selectReflectionParameter:(NSString *)key {
    for (NSDictionary *spec in reflection_parameters())
        if ([spec[@"key"] isEqualToString:key]) { _reflectionParameterKey = [key copy]; break; }
    [self refresh];
}
- (void)reflectionSliderChanged:(UISlider *)slider {
    if (!self.reflectionEditable) return;
    NSDictionary *spec = self.reflectionParameterSpec;
    double step = [spec[@"step"] doubleValue];
    double value = fmin(fmax(round(slider.value / step) * step, [spec[@"min"] doubleValue]), [spec[@"max"] doubleValue]);
    [_reflectionPreferences updateDraft:@{_reflectionParameterKey: @(value)}];
    [self refresh];
}
- (void)selectReflectionCurve:(NSString *)curve {
    if (!self.reflectionEditable || ![@[@"linear", @"smooth", @"bezier"] containsObject:curve]) return;
    [_reflectionPreferences updateDraft:@{@"curve": curve}]; [self refresh];
}
- (void)toggleReflectionEnabled {
    if (!self.reflectionEditable) return;
    [_reflectionPreferences updateDraft:@{@"enabled": @(![_reflectionPreferences.currentSettings[@"enabled"] boolValue])}];
    [self refresh];
}
- (void)toggleReflectionAngleLinked {
    if (!self.reflectionEditable) return;
    [_reflectionPreferences updateDraft:@{@"angleLinked": @(![_reflectionPreferences.currentSettings[@"angleLinked"] boolValue])}];
    [self refresh];
}

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
    [self refreshReflectionControls];
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

- (void)resetDraft {
    if (!_pad || !dm_gamepad_is_layout_editing(_pad)) return;
    if (self.reflectionTab) [_reflectionPreferences resetDraft]; else dm_gamepad_reset_layout_draft(_pad);
    [self refresh];
}
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
    CGFloat targetHeight = _reflectionPreferences ? (self.reflectionTab ? 206 : 160) : 132;
    CGFloat height = MIN(targetHeight, safe.size.height);
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
    CGFloat menuY = _reflectionPreferences ? 78 : 45;
    _menuRow.frame = CGRectMake(8, menuY, available, 34);
    CGFloat menuWidth = MAX(240, available);
    _menuRow.contentSize = CGSizeMake(menuWidth, 34);
    _control.frame = CGRectMake(0, 0, menuWidth / 2 - 4, 34);
    _parameter.frame = CGRectMake(menuWidth / 2 + 4, 0, menuWidth / 2 - 4, 34);
    CGFloat sliderY = _reflectionPreferences ? 116 : 86;
    _slider.frame = CGRectMake(10, sliderY, MAX(0, width - 90), 36);
    _value.frame = CGRectMake(MAX(0, width - 72), sliderY, 62, 36);
    if (_reflectionPreferences) {
        _tabs.frame = CGRectMake(8, 44, available, 26);
        _reflectionSwitchRow.frame = CGRectMake(8, 73, available, 28);
        CGFloat switchWidth = MAX(240, available);
        _reflectionSwitchRow.contentSize = CGSizeMake(switchWidth, 28);
        _reflectionEnabled.frame = CGRectMake(0, 0, switchWidth * .4 - 4, 28);
        _reflectionAngleLinked.frame = CGRectMake(switchWidth * .4 + 4, 0, switchWidth * .6 - 4, 28);
        _reflectionMenuRow.frame = CGRectMake(8, 105, available, 30);
        _reflectionMenuRow.contentSize = CGSizeMake(menuWidth, 30);
        _reflectionParameter.frame = CGRectMake(0, 0, menuWidth * .42 - 4, 30);
        _reflectionCurve.frame = CGRectMake(menuWidth * .42 + 4, 0, menuWidth * .58 - 4, 30);
        _reflectionSlider.frame = CGRectMake(10, 138, MAX(0, width - 90), 30);
        _reflectionValue.frame = CGRectMake(MAX(0, width - 72), 138, 62, 30);
        _reflectionTip.frame = CGRectMake(10, 172, MAX(0, width - 20), 28);
    }
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

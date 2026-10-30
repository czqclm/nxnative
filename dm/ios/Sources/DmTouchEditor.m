// Layout editing uses the runtime pad in its isolated editor mode; only Save persists.
#import "DmGamepad.h"
#import "DmTouchConfig.h"
#import "DmDuoDisplay.h"

@interface DmTouchEditor : UIViewController
- (instancetype)initWithProfile:(NSString *)profile;
@end

@implementation DmTouchEditor {
    NSString *_profile;
    UIView *_preview;
    UIView *_canvas;
    UINavigationBar *_navigation;
    UILabel *_explanation;
    UILabel *_selectionNote;
    UILabel *_scaleValue;
    UIButton *_controlMenu;
    UISlider *_scaleSlider;
    id<UIInteraction> _hingeInteraction;
    NSInteger _lastHingeStatus;
    CGRect _referenceFrame;
    UIEdgeInsets _referenceInsets;
    BOOL _hasReferenceGeometry;
}

static NSString *profile_title(NSString *profile) {
    if ([profile isEqualToString:@"inner"]) return @"展开内屏";
    if ([profile isEqualToString:@"folded"]) return @"折叠双区";
    return @"外屏";
}

static NSArray<NSString *> *control_ids(void) {
    return @[@"LEFT_STICK", @"RIGHT_STICK", @"A", @"B", @"X", @"Y", @"DPAD", @"L", @"R", @"ZL", @"ZR", @"L3", @"R3", @"MINUS", @"PLUS"];
}

static NSString *control_title(NSString *control) {
    if ([control isEqualToString:@"LEFT_STICK"]) return @"左摇杆";
    if ([control isEqualToString:@"RIGHT_STICK"]) return @"右摇杆";
    if ([control isEqualToString:@"DPAD"]) return @"方向键";
    if ([control isEqualToString:@"MINUS"]) return @"－ 键";
    if ([control isEqualToString:@"PLUS"]) return @"＋ 键";
    return control.length ? [control stringByAppendingString:@" 键"] : @"未选择";
}

- (instancetype)initWithProfile:(NSString *)profile {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _profile = [@[@"outer", @"inner", @"folded"] containsObject:profile] ? [profile copy] : @"outer";
        _lastHingeStatus = -1;
        self.modalPresentationStyle = UIModalPresentationFullScreen;
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.view.accessibilityIdentifier = @"touch.editor.screen";
    _navigation = [UINavigationBar new];
    _navigation.translucent = NO;
    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = UIColor.systemBackgroundColor;
    _navigation.standardAppearance = appearance;
    _navigation.scrollEdgeAppearance = appearance;
    UINavigationItem *item = [[UINavigationItem alloc] initWithTitle:[profile_title(_profile) stringByAppendingString:@"按键布局"]];
    UIBarButtonItem *cancel = [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain target:self action:@selector(cancelEditing)];
    cancel.accessibilityIdentifier = @"touch.editor.cancel";
    UIBarButtonItem *save = [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleProminent target:self action:@selector(saveEditing)];
    save.accessibilityIdentifier = @"touch.editor.save";
    UIBarButtonItem *reset = [[UIBarButtonItem alloc] initWithTitle:@"重置布局" style:UIBarButtonItemStylePlain target:self action:@selector(resetLayout)];
    reset.accessibilityIdentifier = @"touch.editor.reset";
    item.leftBarButtonItem = cancel;
    item.rightBarButtonItems = @[save, reset];
    _navigation.items = @[item];
    [self.view addSubview:_navigation];

    _explanation = [UILabel new];
    _explanation.text = @"拖动控件调整位置，轻点后调整大小。\n预览按当前屏幕比例显示，三套布局分别保存。";
    _explanation.numberOfLines = 2;
    _explanation.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _explanation.textColor = UIColor.secondaryLabelColor;
    [self.view addSubview:_explanation];

    _canvas = [UIView new];
    _canvas.backgroundColor = [UIColor colorWithWhite:.065 alpha:1];
    _canvas.clipsToBounds = YES;
    _canvas.layer.cornerRadius = 12;
    _canvas.layer.borderWidth = 1;
    _canvas.layer.borderColor = [UIColor colorWithWhite:.3 alpha:1].CGColor;
    _canvas.accessibilityIdentifier = @"touch.editor.canvas";
    [self.view addSubview:_canvas];
    _preview = dm_gamepad_editor_preview(_profile, dm_touch_profile_settings(_profile));
    _preview.clipsToBounds = YES;
    _preview.accessibilityIdentifier = @"touch.editor.preview";
    [_canvas addSubview:_preview];

    _controlMenu = [UIButton buttonWithType:UIButtonTypeSystem];
    _controlMenu.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    _controlMenu.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    _controlMenu.showsMenuAsPrimaryAction = YES;
    _controlMenu.accessibilityIdentifier = @"touch.editor.control";
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
    __weak DmTouchEditor *weakSelf = self;
    for (NSString *control in control_ids()) {
        UIAction *action = [UIAction actionWithTitle:control_title(control) image:nil identifier:control handler:^(__kindof UIAction *a) {
            (void)a;
            DmTouchEditor *strongSelf = weakSelf;
            if (strongSelf) { dm_gamepad_editor_select(strongSelf->_preview, control); [strongSelf selectionChanged]; }
        }];
        [actions addObject:action];
    }
    _controlMenu.menu = [UIMenu menuWithTitle:@"选择控件" children:actions];
    [self.view addSubview:_controlMenu];

    _selectionNote = [UILabel new];
    _selectionNote.text = @"单个控件大小";
    _selectionNote.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    _selectionNote.textColor = UIColor.secondaryLabelColor;
    [self.view addSubview:_selectionNote];
    _scaleValue = [UILabel new];
    _scaleValue.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightMedium];
    _scaleValue.textAlignment = NSTextAlignmentRight;
    _scaleValue.accessibilityIdentifier = @"touch.editor.scaleValue";
    [self.view addSubview:_scaleValue];
    _scaleSlider = [UISlider new];
    _scaleSlider.minimumValue = .5f;
    _scaleSlider.maximumValue = 1.8f;
    _scaleSlider.continuous = YES;
    _scaleSlider.accessibilityLabel = @"所选控件大小";
    _scaleSlider.accessibilityIdentifier = @"touch.editor.scale";
    [_scaleSlider addTarget:self action:@selector(scaleChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:_scaleSlider];

    dm_gamepad_editor_on_selection(_preview, ^(NSString *control) {
        (void)control;
        [weakSelf selectionChanged];
    });
    dm_gamepad_editor_select(_preview, @"LEFT_STICK");
    [self selectionChanged];

    // A presented editor owns the visible hierarchy, so it must observe its own hinge.
    if (@available(iOS 27.1, *)) {
        _hingeInteraction = [[UIHingeInteraction alloc] initWithUpdateHandler:
            ^(UIHingeInteraction *interaction, UIHingeInteractionUpdate *update) {
                (void)interaction;
                DmTouchEditor *strongSelf = weakSelf; if (!strongSelf) return;
                NSInteger status = update.hinge ? update.hinge.status : -1;
                if (status != strongSelf->_lastHingeStatus) {
                    strongSelf->_lastHingeStatus = status;
                    [strongSelf releaseEditingTouches];
                }
                [strongSelf.view setNeedsLayout];
            }];
        [self.view addInteraction:_hingeInteraction];
    }
    [self registerForTraitChanges:@[UITraitHorizontalSizeClass.class, UITraitVerticalSizeClass.class,
                                   UITraitDisplayScale.class]
        withHandler:^(DmTouchEditor *self, UITraitCollection *previous) {
            (void)previous;
            [self releaseEditingTouches];
            [self.view setNeedsLayout];
        }];
}

- (void)releaseEditingTouches { if (_preview) dm_gamepad_release_touches(_preview); }

- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self releaseEditingTouches];
    [self.view setNeedsLayout];
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [self releaseEditingTouches];
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [self.view setNeedsLayout];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // Reserved regions can be absent until the full-screen view is attached to its scene.
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    UIEdgeInsets insets = self.view.safeAreaInsets;
    CGRect safe = UIEdgeInsetsInsetRect(bounds, insets);
    CGFloat margin = 16, width = MAX(0, safe.size.width - 2 * margin);
    _navigation.frame = CGRectMake(safe.origin.x, safe.origin.y, safe.size.width, 44);
    _explanation.frame = CGRectMake(safe.origin.x + margin, CGRectGetMaxY(_navigation.frame) + 6, width, 40);
    CGFloat bottomTop = CGRectGetMaxY(safe) - 104;
    _controlMenu.frame = CGRectMake(safe.origin.x + margin, bottomTop, width, 36);
    _selectionNote.frame = CGRectMake(safe.origin.x + margin, bottomTop + 37, MAX(0, width - 80), 22);
    _scaleValue.frame = CGRectMake(CGRectGetMaxX(safe) - margin - 76, bottomTop + 37, 76, 22);
    _scaleSlider.frame = CGRectMake(safe.origin.x + margin, bottomTop + 61, width, 36);
    CGFloat canvasTop = CGRectGetMaxY(_explanation.frame) + 8;
    _canvas.frame = CGRectMake(safe.origin.x + margin, canvasTop, width, MAX(1, bottomTop - canvasTop - 8));

    // The pad's geometry is calculated at the runtime size before the whole preview is fitted.
    CGRect referenceFrame = bounds;
    UIEdgeInsets referenceInsets = insets;
    if ([_profile isEqualToString:@"folded"]) {
        CGRect division = CGRectNull;
        BOOL activeDivision = NO;
        if (@available(iOS 27.1, *)) {
            NSArray<UIViewReservedRegion *> *regions = [self.view
                reservedRegionsOfKind:UIViewReservedRegionKind.divisionRegionKind
                options:UIViewReservedRegionQueryOptionsIncludeInactive];
            for (UIViewReservedRegion *region in regions) {
                if (region.isActive && !CGRectIsEmpty(CGRectIntersection(bounds, region.frame))) {
                    division = region.frame; activeDivision = YES; break;
                }
            }
        }
        // Follow the production top/bottom split and its usable horizontal division.
        // With no usable active division the geometry helper supplies the manual fallback.
        CGRect pad = dm_duo_geometry(bounds, insets, YES, division, activeDivision).padFrame;
        referenceFrame = pad;
        // Only the real outside edges inherit a safe inset; the division edge is interior.
        referenceInsets = UIEdgeInsetsMake(fabs(CGRectGetMinY(pad) - CGRectGetMinY(bounds)) < 1 ? insets.top : 0,
                                          fabs(CGRectGetMinX(pad) - CGRectGetMinX(bounds)) < 1 ? insets.left : 0,
                                          fabs(CGRectGetMaxY(pad) - CGRectGetMaxY(bounds)) < 1 ? insets.bottom : 0,
                                          fabs(CGRectGetMaxX(pad) - CGRectGetMaxX(bounds)) < 1 ? insets.right : 0);
    }
    if (!_hasReferenceGeometry || !CGRectEqualToRect(_referenceFrame, referenceFrame) ||
        !UIEdgeInsetsEqualToEdgeInsets(_referenceInsets, referenceInsets)) {
        [self releaseEditingTouches];
        _referenceFrame = referenceFrame; _referenceInsets = referenceInsets; _hasReferenceGeometry = YES;
    }
    CGSize reference = referenceFrame.size;
    if (reference.width <= 0 || reference.height <= 0) reference = CGSizeMake(1, 1);
    CGFloat fit = MIN(_canvas.bounds.size.width / reference.width, _canvas.bounds.size.height / reference.height);
    _preview.transform = CGAffineTransformIdentity;
    _preview.bounds = CGRectMake(0, 0, reference.width, reference.height);
    dm_gamepad_editor_set_safe_insets(_preview, referenceInsets);
    _preview.center = CGPointMake(CGRectGetMidX(_canvas.bounds), CGRectGetMidY(_canvas.bounds));
    _preview.transform = CGAffineTransformMakeScale(fit, fit);
    [_preview setNeedsLayout];
}

- (void)selectionChanged {
    NSString *control = dm_gamepad_editor_selection(_preview);
    [_controlMenu setTitle:[NSString stringWithFormat:@"控件：%@ ▾", control_title(control)] forState:UIControlStateNormal];
    NSDictionary *layout = dm_gamepad_editor_settings(_preview)[@"controls"];
    NSNumber *scale = layout[control][@"scale"];
    CGFloat value = scale ? scale.doubleValue : 1;
    _scaleSlider.value = (float)value;
    _scaleValue.text = [NSString stringWithFormat:@"%.0f%%", value * 100];
    _scaleSlider.enabled = control.length != 0;
}

- (void)scaleChanged:(UISlider *)slider {
    dm_gamepad_editor_set_scale(_preview, slider.value);
    [self selectionChanged];
}

- (void)resetLayout {
    dm_gamepad_editor_reset_layout(_preview);
    dm_gamepad_editor_select(_preview, @"LEFT_STICK");
    [self selectionChanged];
}

- (void)cancelEditing { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)saveEditing {
    dm_touch_save_profile(_profile, dm_gamepad_editor_settings(_preview));
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

UIViewController *dm_touch_editor_controller(NSString *profile) {
    return [[DmTouchEditor alloc] initWithProfile:profile];
}

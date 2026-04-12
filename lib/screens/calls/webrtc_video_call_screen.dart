import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:deepinheart/services/webrtc_service.dart';
import 'package:deepinheart/services/call_state_manager.dart';
import 'package:deepinheart/screens/calls/widgets/coin_balance_widget.dart';
import 'package:deepinheart/screens/calls/widgets/call_rating_dialog.dart';
import 'package:deepinheart/Controller/Viewmodel/userviewmodel.dart';
import 'package:deepinheart/Controller/Viewmodel/setting_provider.dart';
import 'package:deepinheart/Controller/Model/settings_model.dart';
import 'package:deepinheart/config/webrtc_config.dart';
import 'package:deepinheart/config/api_endpoints.dart';
import 'package:deepinheart/views/colors.dart';
import 'package:deepinheart/views/custom_text.dart';
import 'package:deepinheart/views/font_constants.dart';
import 'package:deepinheart/views/ui_helpers.dart';

class WebRTCVideoCallScreen extends StatefulWidget {
  final String counselorName;
  final String channelName;
  final int userId;
  final double counselorRate;
  final int? appointmentId;
  final int? counselorId;
  final String? counselorImage;
  final bool isCounselor;
  final bool isTroat;

  const WebRTCVideoCallScreen({
    Key? key,
    required this.counselorName,
    required this.channelName,
    required this.userId,
    this.counselorRate = 50.0,
    this.appointmentId,
    this.counselorId,
    this.counselorImage,
    required this.isCounselor,
    required this.isTroat,
  }) : super(key: key);

  @override
  State<WebRTCVideoCallScreen> createState() => _WebRTCVideoCallScreenState();
}

class _WebRTCVideoCallScreenState extends State<WebRTCVideoCallScreen>
    with WidgetsBindingObserver {
  WebRTCService? _webrtcService;
  RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  bool _isLoading = true;
  bool _isConnected = false;
  bool _isMuted = false;
  bool _isVideoEnabled = true;
  bool _isFrontCamera = true;
  bool _isWaitingForReconnection = false;

  Timer? _callTimer;
  Timer? _coinDeductionTimer;
  Duration _callDuration = Duration.zero;

  double _coinsLeft = 0.0;
  double _initialCoins = 0.0;
  late double _coinsPerMinute;
  late double _coinsPerSecond;

  static const int LOW_COINS_THRESHOLD = 100;
  bool _lowCoinsWarningShown = false;
  bool _lessMinuteWarningShown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _coinsPerMinute = widget.counselorRate;
    _coinsPerSecond = _coinsPerMinute / 60.0;

    _initializeCall();
  }

  Future<void> _loadUserCoins() async {
    try {
      final userProvider = Provider.of<UserViewModel>(
        context,
        listen: false,
      );
      _coinsLeft = (userProvider.userModel?.data.coins ?? 0).toDouble();
      _initialCoins = _coinsLeft;
    } catch (e) {
      debugPrint('❌ Failed to load user coins: $e');
    }
  }

  Future<void> _initializeCall() async {
    try {
      setState(() {
        _isLoading = true;
      });

      // Initialize renderers
      await _localRenderer.initialize();
      await _remoteRenderer.initialize();

      // Get user coins
      await _loadUserCoins();

      // Initialize WebRTC service
      final roomId = widget.channelName;
      final userId = widget.userId.toString();

      _webrtcService = WebRTCService();

      // Listen to service events
      _webrtcService!.connectionState.listen(_onConnectionStateChanged);
      _webrtcService!.remoteStream.listen(_onRemoteStream);
      _webrtcService!.errorStream.listen(_onError);

      // Get signaling URL from settings
      final settingsProvider = Provider.of<SettingProvider>(context, listen: false);
      final signalingUrl = settingsProvider.settings?.webrtcServerUrl ?? '';
      
      // Initialize WebRTC
      await _webrtcService!.initialize(
        context: context,
        isVideoCall: true,
        roomId: roomId,
        userId: userId,
        signalingUrl: signalingUrl,
      );

      // Set local renderer
      if (_webrtcService!.localStream != null) {
        setState(() {
          _localRenderer.srcObject = _webrtcService!.localStream;
        });
      }

      // Start call timer (will be updated when connected)
      _startCallTimer();
      
      // Send start_time API for counselors
      if (widget.isCounselor) {
        _sendStartTimeApi();
      }

      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('❌ Failed to initialize WebRTC call: $e');
      _showErrorDialog('Failed to initialize call: $e');
    }
  }

  Future<void> _sendStartTimeApi() async {
    if (!widget.isCounselor || widget.appointmentId == null) return;

    try {
      final userViewModel = Provider.of<UserViewModel>(context, listen: false);
      final token = userViewModel.userModel?.data.token;
      if (token == null) return;

      final now = DateTime.now();
      final startTime = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';

      debugPrint('[WebRTC] Sending start_time API: $startTime');

      final request = http.MultipartRequest(
        'POST',
        Uri.parse(ApiEndPoints.UPDATE_TIME),
      );
      request.headers['Authorization'] = 'Bearer $token';
      request.fields['appointment_id'] = widget.appointmentId.toString();
      request.fields['start_time'] = startTime;
      request.fields['coins'] = '0';

      await request.send();
    } catch (e) {
      debugPrint('[WebRTC] Error sending start_time API: $e');
    }
  }

  Future<void> _sendEndTimeApi() async {
    if (widget.appointmentId == null) return;

    try {
      final userViewModel = Provider.of<UserViewModel>(context, listen: false);
      final token = userViewModel.userModel?.data.token;
      if (token == null) return;

      final now = DateTime.now();
      final endTime = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
      
      final durationInMinutes = _callDuration.inSeconds / 60.0;
      final coinsBasedOnDuration = (durationInMinutes * widget.counselorRate).toInt().toString();

      debugPrint('[WebRTC] Sending end_time API: $endTime, coins: $coinsBasedOnDuration');

      final request = http.MultipartRequest(
        'POST',
        Uri.parse(ApiEndPoints.UPDATE_TIME),
      );
      request.headers['Authorization'] = 'Bearer $token';
      request.fields['appointment_id'] = widget.appointmentId.toString();
      request.fields['end_time'] = endTime;
      request.fields['coins'] = coinsBasedOnDuration;

      await request.send();
    } catch (e) {
      debugPrint('[WebRTC] Error sending end_time API: $e');
    }
  }

  Future<void> _completeAppointmentApi() async {
    if (widget.appointmentId == null || widget.counselorId == null) return;

    try {
      final userViewModel = Provider.of<UserViewModel>(context, listen: false);
      final token = userViewModel.userModel?.data.token;
      if (token == null) return;

      debugPrint('[WebRTC] Calling complete-appointment API');

      await http.post(
        Uri.parse('${ApiEndPoints.BASE_URL}complete-appointment'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'appointment_id': widget.appointmentId,
          'counselor_id': widget.counselorId,
        }),
      );
    } catch (e) {
      debugPrint('[WebRTC] Error calling complete-appointment API: $e');
    }
  }

  void _onConnectionStateChanged(WebRTCConnectionState state) {
    if (mounted) {
      setState(() {
        switch (state) {
          case WebRTCConnectionState.connected:
            _isConnected = true;
            _isWaitingForReconnection = false;
            break;
          case WebRTCConnectionState.connecting:
            _isConnected = false;
            break;
          case WebRTCConnectionState.disconnected:
          case WebRTCConnectionState.failed:
            _isConnected = false;
            // For WebRTC, we might want to show reconnection UI instead of immediate end
            _isWaitingForReconnection = true;
            break;
          default:
            _isConnected = false;
            break;
        }
      });
    }
  }

  void _onRemoteStream(MediaStream stream) {
    if (mounted) {
      setState(() {
        _remoteRenderer.srcObject = stream;
      });
    }
  }

  void _onError(String error) {
    debugPrint('❌ WebRTC error: $error');
    // _showErrorDialog(error);
  }

  void _startCallTimer() {
    _callTimer?.cancel();
    _callTimer = Timer.periodic(Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _callDuration = Duration(seconds: _callDuration.inSeconds + 1);
        });

        // Deduct coins every second if connected and not counselor
        if (!widget.isCounselor && _isConnected) {
          _deductCoins();
        }

        // Check for warnings
        _checkCoinWarnings();
      }
    });
  }

  void _deductCoins() {
    if (_coinsLeft <= 0) {
      _handleInsufficientCoins();
      return;
    }

    setState(() {
      _coinsLeft -= _coinsPerSecond;
      if (_coinsLeft < 0) _coinsLeft = 0;
    });

    // Optional: Sync with provider less frequently if needed
    // final userProvider = Provider.of<UserViewModel>(context, listen: false);
    // userProvider.updateCoins(_coinsLeft.toInt());
  }

  void _checkCoinWarnings() {
    // Low coins warning
    if (_coinsLeft < LOW_COINS_THRESHOLD && !_lowCoinsWarningShown) {
      _lowCoinsWarningShown = true;
      _showLowCoinsWarning();
    }

    // Less than 1 minute warning
    final minutesLeft = _coinsLeft / _coinsPerMinute;
    if (minutesLeft < 1.0 && !_lessMinuteWarningShown && _coinsLeft > 0) {
      _lessMinuteWarningShown = true;
      _showLessMinuteWarning();
    }
  }

  void _showLowCoinsWarning() {
    Get.snackbar(
      '⚠️ Low Coins Warning'.tr,
      'You have less than $LOW_COINS_THRESHOLD coins remaining.'.tr,
      backgroundColor: Colors.orange,
      colorText: Colors.white,
      duration: Duration(seconds: 5),
      snackPosition: SnackPosition.TOP,
      margin: EdgeInsets.all(20),
      borderRadius: 10,
      icon: Icon(Icons.warning_amber, color: Colors.white),
      shouldIconPulse: true,
    );
  }

  void _showLessMinuteWarning() {
    Get.snackbar(
      '⚠️ Call Ending Soon'.tr,
      'Less than 1 minute remaining. Please recharge to continue.'.tr,
      backgroundColor: Colors.red,
      colorText: Colors.white,
      snackPosition: SnackPosition.TOP,
      duration: Duration(seconds: 10),
      margin: EdgeInsets.all(20),
      borderRadius: 10,
      icon: Icon(Icons.timer_off, color: Colors.white),
      shouldIconPulse: true,
      isDismissible: false,
    );
  }

  void _handleInsufficientCoins() {
    _endCall(showRating: true);
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text('Error'.tr),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () {
                  Get.back();
                  _endCall();
                },
                child: Text('OK'.tr),
              ),
            ],
          ),
    );
  }

  Future<void> _toggleMute() async {
    await _webrtcService?.toggleMicrophone();
    if (mounted) {
      setState(() {
        _isMuted = !_isMuted;
      });
    }
  }

  Future<void> _toggleCamera() async {
    await _webrtcService?.toggleCamera();
    if (mounted) {
      setState(() {
        _isVideoEnabled = !_isVideoEnabled;
      });
    }
  }

  Future<void> _switchCamera() async {
    await _webrtcService?.switchCamera();
    if (mounted) {
      setState(() {
        _isFrontCamera = !_isFrontCamera;
      });
    }
  }

  Future<void> _endCall({bool showRating = true}) async {
    _callTimer?.cancel();
    _coinDeductionTimer?.cancel();
    
    // Clear saved call state
    await CallStateManager.clearCallState();

    if (!widget.isCounselor) {
      await _sendEndTimeApi();
      await _completeAppointmentApi();

      if (showRating && widget.appointmentId != null && widget.counselorId != null) {
        _webrtcService?.dispose();
        
        if (mounted) {
          Navigator.of(context).pop();
        }

        await Future.delayed(Duration(milliseconds: 300));

        await Get.dialog(
          CallRatingDialog(
            appointmentId: widget.appointmentId!,
            counselorId: widget.counselorId!,
            counselorName: widget.counselorName,
            counselorImage: widget.counselorImage,
            callDuration: _callDuration,
          ),
          barrierDismissible: false,
        );
        return;
      }
    }

    _webrtcService?.dispose();
    if (mounted) {
      Get.back();
    }
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds";
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _callTimer?.cancel();
    _coinDeductionTimer?.cancel();
    _webrtcService?.dispose();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    switch (state) {
      case AppLifecycleState.paused:
        _saveCurrentCallState();
        break;
      case AppLifecycleState.resumed:
        CallStateManager.clearCallState();
        break;
      case AppLifecycleState.detached:
        _saveCurrentCallState();
        break;
      default:
        break;
    }
  }

  void _saveCurrentCallState() {
    if (!_isConnected) return;

    CallStateManager.saveCallState(
      callType: 'video',
      channelName: widget.channelName,
      counselorName: widget.counselorName,
      userId: widget.userId,
      counselorRate: widget.counselorRate,
      appointmentId: widget.appointmentId,
      counselorId: widget.counselorId,
      counselorImage: widget.counselorImage,
      isCounselor: widget.isCounselor,
      callDurationSeconds: _callDuration.inSeconds,
      coinsLeft: _coinsLeft,
      isTroat: widget.isTroat,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // Video views
            _buildVideoViews(),

            // Top info bar
            _buildTopBar(),

            // Coins and Tarot
            Positioned(
              bottom: 80,
              child: Container(
                width: Get.width,
                padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 10.h),
                child: Row(
                  children: [
                    buildCoinsWidget(),
                    Spacer(),
                    widget.isTroat
                        ? buildSettingsButton(context, widget.isCounselor)
                        : SizedBox.shrink(),
                  ],
                ),
              ),
            ),

            // Bottom controls
            _buildBottomControls(),

            // Loading overlay
            if (_isLoading || _isWaitingForReconnection) _buildLoadingOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoViews() {
    return Container(
      width: double.infinity,
      height: double.infinity,
      child: Stack(
        children: [
          // Remote video (full screen)
          if (_remoteRenderer.srcObject != null)
            RTCVideoView(
              _remoteRenderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            )
          else
            Container(
              color: Colors.grey[900],
              child: _isWaitingForReconnection
                  ? Container()
                  : Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.person,
                            size: 80.w,
                            color: Colors.white54,
                          ),
                          UIHelper.verticalSpaceMd,
                          CustomText(
                            text: "${'Waiting for'.tr} ${widget.counselorName} ${'to join...'.tr}",
                            fontSize: FontConstants.font_16,
                            weight: FontWeightConstants.medium,
                            color: Colors.white70,
                          ),
                        ],
                      ),
                    ),
            ),

          // Local video (picture-in-picture)
          if (_isVideoEnabled && _localRenderer.srcObject != null)
            Positioned(
              top: 100.h,
              right: 20.w,
              child: Container(
                width: 120.w,
                height: 160.h,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12.r),
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 8,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10.r),
                  child: RTCVideoView(
                    _localRenderer,
                    mirror: _isFrontCamera,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 15.h),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black.withOpacity(0.6), Colors.transparent],
          ),
        ),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Back button
                GestureDetector(
                  onTap: () {
                    _showEndCallConfirmation();
                  },
                  child: Container(
                    padding: EdgeInsets.all(10.w),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.4),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.arrow_back,
                      color: Colors.white,
                      size: 22.w,
                    ),
                  ),
                ),
                SizedBox(width: 40.w),
              ],
            ),
            UIHelper.verticalSpaceSm,
            CustomText(
              text: widget.counselorName,
              fontSize: FontConstants.font_18,
              weight: FontWeightConstants.semiBold,
              color: Colors.white,
            ),
            SizedBox(height: 4.h),
            CustomText(
              text: _formatDuration(_callDuration),
              fontSize: FontConstants.font_14,
              weight: FontWeightConstants.medium,
              color: Colors.white70,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomControls() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(20.w, 30.h, 20.w, 30.h),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              Colors.black.withOpacity(0.7),
              Colors.black.withOpacity(0.3),
              Colors.transparent,
            ],
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Flip Camera button
            _buildControlButton(
              icon: _isFrontCamera ? Icons.camera_front : Icons.camera_rear,
              isActive: true,
              onTap: _switchCamera,
              size: 56.w,
            ),

            SizedBox(width: 20.w),

            // End call button (RED)
            _buildControlButton(
              icon: Icons.call_end,
              isActive: false,
              backgroundColor: Colors.red,
              onTap: _showEndCallConfirmation,
              size: 56.w,
            ),

            SizedBox(width: 20.w),

            // Microphone button
            _buildControlButton(
              icon: _isMuted ? Icons.mic_off : Icons.mic,
              isActive: !_isMuted,
              onTap: _toggleMute,
              size: 56.w,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required bool isActive,
    required VoidCallback onTap,
    Color? backgroundColor,
    double? size,
  }) {
    final buttonSize = size ?? 60.w;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: buttonSize,
        height: buttonSize,
        decoration: BoxDecoration(
          color: backgroundColor ?? (isActive ? Colors.white : Colors.white.withOpacity(0.3)),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.2),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Icon(
          icon,
          color: backgroundColor != null ? Colors.white : (isActive ? Colors.black : Colors.white),
          size: buttonSize * 0.45,
        ),
      ),
    );
  }

  Widget buildCoinsWidget() {
    return CoinBalanceWidget(
      coinsLeft: _coinsLeft,
      estimatedMinutesLeft: (_coinsLeft / _coinsPerMinute).floor(),
      lowCoinsThreshold: LOW_COINS_THRESHOLD,
      isCounselor: widget.isCounselor,
    );
  }

  Widget buildSettingsButton(BuildContext context, bool isCounselor) {
    return GestureDetector(
      onTap: () {
        _openTarotWebBrowser(context, isCounselor);
      },
      child: Container(
        width: 48.w,
        height: 48.w,
        decoration: BoxDecoration(
          color: primaryColor,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withOpacity(0.2), width: 1),
        ),
        child: Icon(Icons.star, color: Colors.white, size: 24.w),
      ),
    );
  }

  void _openTarotWebBrowser(BuildContext context, bool isCounselor) {
    late final WebViewController controller;

    final settingsProvider = context.read<SettingProvider>();
    if (settingsProvider.settingsModel == null) return;
    
    SettingsData settings = settingsProvider.settingsModel!.data;
    final String tarotUrl1 = isCounselor ? settings.tarotCounselorsUrl : settings.tarotQuerentsUrl;

    final String tarotUrl = tarotUrl1.isNotEmpty
        ? tarotUrl1
        : isCounselor
            ? 'http://47.236.118.189:443'
            : 'http://47.236.118.189:443/querents';

    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..enableZoom(true)
      ..loadRequest(Uri.parse(tarotUrl));

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      isDismissible: true,
      enableDrag: false,
      builder: (context) => Container(
        height: Get.height * 0.95,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(20.r),
            topRight: Radius.circular(20.r),
          ),
        ),
        child: Column(
          children: [
            Container(
              padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(20.r),
                  topRight: Radius.circular(20.r),
                ),
                border: Border(bottom: BorderSide(color: Colors.grey[200]!, width: 1)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(Icons.auto_stories, color: primaryColor, size: 24.w),
                      SizedBox(width: 10.w),
                      CustomText(
                        text: "Tarot Reading".tr,
                        fontSize: FontConstants.font_16,
                        weight: FontWeightConstants.semiBold,
                        color: Colors.black87,
                      ),
                    ],
                  ),
                  GestureDetector(
                    onTap: () => Get.back(),
                    child: Container(
                      padding: EdgeInsets.all(8.w),
                      decoration: BoxDecoration(color: Colors.grey[100], shape: BoxShape.circle),
                      child: Icon(Icons.close, color: Colors.black87, size: 20.w),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: WebViewWidget(controller: controller)),
          ],
        ),
      ),
    );
  }

  void _showEndCallConfirmation() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20.r)),
        title: CustomText(
          text: "End Call?".tr,
          fontSize: FontConstants.font_18,
          weight: FontWeightConstants.bold,
          color: Colors.black87,
        ),
        content: CustomText(
          text: "Are you sure you want to end this call?".tr,
          fontSize: FontConstants.font_14,
          weight: FontWeightConstants.regular,
          color: Colors.black54,
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: CustomText(
              text: "Cancel".tr,
              fontSize: FontConstants.font_14,
              weight: FontWeightConstants.medium,
              color: Colors.grey[600]!,
            ),
          ),
          TextButton(
            onPressed: () {
              Get.back();
              _endCall();
            },
            child: CustomText(
              text: "End Call".tr,
              fontSize: FontConstants.font_14,
              weight: FontWeightConstants.bold,
              color: Colors.red,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingOverlay() {
    return Container(
      color: Colors.black.withOpacity(0.8),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(valueColor: AlwaysStoppedAnimation<Color>(primaryColor)),
            UIHelper.verticalSpaceMd,
            CustomText(
              text: _isWaitingForReconnection ? "Waiting for reconnection...".tr : "Connecting to call...".tr,
              fontSize: FontConstants.font_16,
              weight: FontWeightConstants.medium,
              color: Colors.white,
            ),
            if (_isWaitingForReconnection) ...[
              UIHelper.verticalSpaceSm,
              CustomText(
                text: "The other user will rejoin shortly".tr,
                fontSize: FontConstants.font_14,
                weight: FontWeightConstants.regular,
                color: Colors.white70,
              ),
              UIHelper.verticalSpaceL,
              ElevatedButton(
                onPressed: () => _endCall(showRating: true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  padding: EdgeInsets.symmetric(horizontal: 30.w, vertical: 12.h),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25.r)),
                ),
                child: CustomText(
                  text: "End Call".tr,
                  fontSize: FontConstants.font_14,
                  weight: FontWeightConstants.bold,
                  color: Colors.white,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

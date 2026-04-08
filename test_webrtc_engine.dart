import 'package:flutter/material.dart';
import 'package:deepinheart/Controller/Viewmodel/setting_provider.dart';
import 'package:deepinheart/utils/call_engine_selector.dart';
import 'package:deepinheart/services/webrtc_service.dart';

/// WebRTC Engine Testing Script
/// Tests switching between WebRTC and Agora engines
void main() async {
  print('=== WebRTC Engine Testing ===\n');

  // Test 1: Check current settings
  await _testCurrentSettings();
  
  // Test 2: Test engine selection logic
  await _testEngineSelection();
  
  // Test 3: Test WebRTC URL configuration
  await _testWebRtcUrlConfig();
  
  print('\n=== Testing Complete ===');
}

Future<void> _testCurrentSettings() async {
  print('ð Test 1: Current Settings Check');
  print('=' * 50);
  
  try {
    // Mock settings with current values
    final mockSettings = SettingsData(
      customerPhoneService: '+82 (032) 888-8849',
      customerServiceEmail: 'mwc718@naver.com',
      appVersion: '1.0.0',
      minimumSupportedVersion: '1.0.0',
      showMaintenanceMode: false,
      maintenanceMessage: '',
      maintenanceStartTime: '',
      maintenanceEndTime: '',
      completeServiceShutdown: false,
      serviceShutdownMessage: '',
      emailRegistration: true,
      phoneRegistration: true,
      kakaoIntegration: true,
      appleIntegration: true,
      minNicknameLength: 2,
      maxNicknameLength: 20,
      allowSpecialCharactersInNickname: true,
      prohibitedWords: '',
      idCardCopy: false,
      licenseCopy: false,
      resume: false,
      applicationSelfIntro: false,
      bankAccountCopy: false,
      profileName: true,
      profilePhoto: true,
      profileSelfIntro: true,
      specialization: true,
      experience: true,
      certificates: true,
      bNumberOfCoins: 0,
      bCoinPrice: 0,
      hideNegativeReviews: false,
      allowCounselorReviewResponses: true,
      reviewEditPeriod: 0,
      minCoinRate: 0,
      maxCoinRate: 0,
      cusAmountOver: 0,
      cusNumberOfCoins: 0,
      cusPrice: 0,
      cusDiscountRate: 0,
      refundPolicySection: '',
      autoSignupCouponEnabled: false,
      signupCouponAmount: '',
      signupCouponName: '',
      autoBirthdayCouponEnabled: false,
      birthdayCouponAmount: '',
      birthdayCouponName: '',
      autoReturnUserCouponEnabled: false,
      returnUserInactiveDays: '',
      returnUserCouponAmount: '',
      returnUserCouponName: '',
      defaultCouponValidityDays: '',
      reviewFilterWords: '',
      autoApproveReviews: true,
      allowGlobalPush: true,
      pushSystemErrorAlerts: true,
      pushPaymentNotifications: true,
      pushBookingNotifications: true,
      pushEventsPromotions: true,
      lowCoinBalanceThreshold: '',
      inactiveUserReminderDays: '',
      pushBirthdayMessage: true,
      pushTemplateLowCoin: '',
      pushTemplateInactiveUser: '',
      pushTemplateBirthday: '',
      pushTemplateBookingConfirm: '',
      pushTemplateBookingCancel: '',
      callServiceType: 'custom', // Current value from API
      agoraAppId: 'feea262b819f424f9374f955abe113c7',
      agoraAppCertificate: '',
      webrtcServerUrl: 'ws://158.247.241.227:3000', // Current value from API
      webrtcServerApiKey: '',
      privacyPolicyLink: '',
      termsOfUseLink: '',
      marketingInfoLink: '',
      tarotCounselorsUrl: '',
      tarotQuerentsUrl: '',
      logHistoryEnabled: false,
      autoBackupEnabled: false,
      backupFrequency: '',
      backupRetentionDays: 0,
      vat: 0.0,
    );

    print('â Call Service Type: ${mockSettings.callServiceType}');
    print('â WebRTC Server URL: ${mockSettings.webrtcServerUrl}');
    print('â Agora App ID: ${mockSettings.agoraAppId}');
    print('â Settings loaded successfully');
    
  } catch (e) {
    print('â Error loading settings: $e');
  }
  
  print('\n');
}

Future<void> _testEngineSelection() async {
  print('ð Test 2: Engine Selection Logic');
  print('=' * 50);
  
  final testCases = [
    ('webrtc', 'WebRTC'),
    ('custom', 'WebRTC'), // Should work with our fix
    ('agora', 'Agora'),
    ('unknown', 'Agora'), // Default fallback
    ('', 'Agora'), // Default fallback
  ];
  
  for (final testCase in testCases) {
    final (serviceType, expectedEngine) = testCase;
    print('Testing: "$serviceType" -> Expected: $expectedEngine');
    
    // Mock the logic from CallEngineSelector
    final callServiceType = serviceType.toLowerCase();
    CallEngine engine;
    
    switch (callServiceType) {
      case 'webrtc':
      case 'custom':
        engine = CallEngine.webrtc;
        break;
      case 'agora':
      default:
        engine = CallEngine.agora;
        break;
    }
    
    final actualEngine = engine.name;
    final status = (actualEngine == expectedEngine) ? 'â PASS' : 'â FAIL';
    print('  Result: $actualEngine $status');
  }
  
  print('\n');
}

Future<void> _testWebRtcUrlConfig() async {
  print('ð Test 3: WebRTC URL Configuration');
  print('=' * 50);
  
  final testUrls = [
    'ws://158.247.241.227:3000',
    'wss://your-server.com:8080',
    '',
    null,
  ];
  
  for (final url in testUrls) {
    print('Testing URL: "$url"');
    
    if (url == null || url.trim().isEmpty) {
      print('  Result: â FAIL - URL is empty');
    } else {
      print('  Result: â PASS - URL is valid');
      print('  Protocol: ${url.split('://')[0]}');
      print('  Host: ${url.split('://')[1].split(':')[0]}');
      print('  Port: ${url.split('://')[1].split(':')[1]}');
    }
    print('');
  }
}

enum CallEngine {
  agora,
  webrtc,
}

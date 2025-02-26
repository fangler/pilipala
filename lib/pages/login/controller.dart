import 'dart:async';
import 'dart:io';

import 'package:PiliPalaX/common/constants.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:PiliPalaX/http/login.dart';
import 'package:gt3_flutter_plugin/gt3_flutter_plugin.dart';
import 'package:PiliPalaX/models/login/index.dart';
import '../../utils/login.dart';
import 'package:hive/hive.dart';
import 'package:webview_cookie_manager/webview_cookie_manager.dart';

import '../../http/constants.dart';
import '../../http/init.dart';
import '../../http/user.dart';
import '../../utils/storage.dart';
import '../home/controller.dart';
import '../media/controller.dart';

class LoginPageController extends GetxController
    with GetSingleTickerProviderStateMixin {
  final TextEditingController telTextController = TextEditingController();
  final TextEditingController usernameTextController = TextEditingController();
  final TextEditingController passwordTextController = TextEditingController();
  final TextEditingController smsCodeTextController = TextEditingController();

  Rx<Map<String, dynamic>> codeInfo = Rx<Map<String, dynamic>>({});

  late TabController tabController;

  final Gt3FlutterPlugin captcha = Gt3FlutterPlugin();

  CaptchaDataModel captchaData = CaptchaDataModel();
  RxInt qrCodeLeftTime = 180.obs;
  Rx<String> statusQRCode = ''.obs;

  Map<String, dynamic> selectedCountryCodeId =
      Constants.internationalDialingPrefix.first;
  String captchaKey = '';
  RxInt smsSendCooldown = 0.obs;
  int smsSendTimestamp = 0;

  // 定时器
  Timer? qrCodeTimer;
  Timer? smsSendCooldownTimer;

  @override
  void onInit() {
    super.onInit();
    tabController = TabController(length: 3, vsync: this)
      ..addListener(_handleTabChange);
  }

  @override
  void onClose() {
    tabController.removeListener(_handleTabChange);
    tabController.dispose();
    qrCodeTimer?.cancel();
    smsSendCooldownTimer?.cancel();
    super.onClose();
  }

  void refreshQRCode() {
    LoginHttp.getHDcode().then((res) {
      if (res['status']) {
        qrCodeTimer?.cancel();
        codeInfo.value = res;
        codeInfo.refresh();
        print("codeInfo");
        print(codeInfo);
        qrCodeTimer = Timer.periodic(const Duration(milliseconds: 1000), (t) {
          qrCodeLeftTime.value = 180 - t.tick;
          if (qrCodeLeftTime <= 0) {
            t.cancel();
            statusQRCode.value = '二维码已过期，请刷新';
            qrCodeLeftTime = 0.obs;
            return;
          }

          LoginHttp.codePoll(codeInfo.value['data']['auth_code'])
              .then((value) async {
            if (value['status']) {
              t.cancel();
              statusQRCode.value = '扫码成功';
              print(value['data']);
              await afterLoginByApp(
                  value['data'], value['data']['cookie_info']);
              Get.back();
            } else if (value['code'] == 86038) {
              t.cancel();
              qrCodeLeftTime = 0.obs;
            } else {
              statusQRCode.value = value['msg'];
            }
          });
        });
      } else {
        SmartDialog.showToast(res['msg']);
      }
    });
  }

  void _handleTabChange() {
    print('tabController.index ${tabController.index}');
    if (tabController.index == 2) {
      if (qrCodeTimer == null || qrCodeTimer!.isActive == false) {
        refreshQRCode();
      }
    }
  }

  Future afterLoginByApp(Map<String, dynamic> token_info, cookie_info) async {
    try {
      Box localCache = GStorage.localCache;
      localCache.put(LocalCacheKey.accessKey, {
        'mid': token_info['mid'],
        'value': token_info['access_token'],
        'refresh': token_info['refresh_token']
      });
      List<dynamic> cookieInfo = cookie_info['cookies'];
      print("cookieInfo");
      print(cookieInfo);
      List<Cookie> cookies = [];
      String cookieStrings = cookieInfo.map((cookie) {
        String cstr =
            '${cookie['name']}=${cookie['value']};Domain=.bilibili.com;Path=/;';
        cookies.add(Cookie.fromSetCookieValue(cstr));
        return cstr;
      }).join('');
      List<String> Urls = [
        HttpString.baseUrl,
        HttpString.apiBaseUrl,
        HttpString.tUrl
      ];
      for (var url in Urls) {
        await Request.cookieManager.cookieJar
            .saveFromResponse(Uri.parse(url), cookies);
      }
      print(cookieStrings);
      print(Request.cookieManager.cookieJar
          .loadForRequest(Uri.parse(HttpString.apiBaseUrl)));
      Request.dio.options.headers['cookie'] = cookieStrings;
      print(Request.dio.options);
      await WebviewCookieManager().setCookies(cookies);
    } catch (e) {
      SmartDialog.showToast('设置登录态失败，$e');
    }
    final result = await UserHttp.userInfo();
    if (result['status'] && result['data'].isLogin) {
      SmartDialog.showToast('登录成功，当前采用「'
          '${GStorage.setting.get(SettingBoxKey.defaultRcmdType, defaultValue: 'web')}'
          '端」推荐');
      Box userInfoCache = GStorage.userInfo;
      await userInfoCache.put('userInfoCache', result['data']);
      final HomeController homeCtr = Get.find<HomeController>();
      homeCtr.updateLoginStatus(true);
      homeCtr.userFace.value = result['data'].face;
      final MediaController mediaCtr = Get.find<MediaController>();
      mediaCtr.mid = result['data'].mid;
      await LoginUtils.refreshLoginStatus(true);
    } else {
      // 获取用户信息失败
      SmartDialog.showNotify(
          msg: '登录失败，请检查cookie是否正确，${result['message']}',
          notifyType: NotifyType.warning);
    }
  }

  // 申请极验验证码
  Future getCaptcha(geeGt, geeChallenge, onSuccess) async {
    var registerData = Gt3RegisterData(
      challenge: geeChallenge,
      gt: geeGt,
      success: true,
    );

    captcha.addEventHandler(
        onShow: (Map<String, dynamic> message) async {},
        onClose: (Map<String, dynamic> message) async {
          SmartDialog.showToast('关闭验证');
        },
        onResult: (Map<String, dynamic> message) async {
          debugPrint("Captcha result: $message");
          String code = message["code"];
          if (code == "1") {
            // 发送 message["result"] 中的数据向 B 端的业务服务接口进行查询
            SmartDialog.showToast('验证成功');
            captchaData.validate = message['result']['geetest_validate'];
            captchaData.seccode = message['result']['geetest_seccode'];
            captchaData.geetest = GeetestData(
              challenge: message['result']['geetest_challenge'],
              gt: geeGt,
            );
            onSuccess();
          } else {
            // 终端用户完成验证失败，自动重试 If the verification fails, it will be automatically retried.
            debugPrint("Captcha result code : $code");
          }
        },
        onError: (Map<String, dynamic> message) async {
          SmartDialog.showToast("Captcha onError: $message");
          String code = message["code"];
          // 处理验证中返回的错误 Handling errors returned in verification
          if (Platform.isAndroid) {
            // Android 平台
            if (code == "-2") {
              // Dart 调用异常 Call exception
            } else if (code == "-1") {
              // Gt3RegisterData 参数不合法 Parameter is invalid
            } else if (code == "201") {
              // 网络无法访问 Network inaccessible
            } else if (code == "202") {
              // Json 解析错误 Analysis error
            } else if (code == "204") {
              // WebView 加载超时，请检查是否混淆极验 SDK   Load timed out
            } else if (code == "204_1") {
              // WebView 加载前端页面错误，请查看日志 Error loading front-end page, please check the log
            } else if (code == "204_2") {
              // WebView 加载 SSLError
            } else if (code == "206") {
              // gettype 接口错误或返回为 null   API error or return null
            } else if (code == "207") {
              // getphp 接口错误或返回为 null    API error or return null
            } else if (code == "208") {
              // ajax 接口错误或返回为 null      API error or return null
            } else {
              // 更多错误码参考开发文档  More error codes refer to the development document
              // https://docs.geetest.com/sensebot/apirefer/errorcode/android
            }
          }

          if (Platform.isIOS) {
            // iOS 平台
            if (code == "-1009") {
              // 网络无法访问 Network inaccessible
            } else if (code == "-1004") {
              // 无法查找到 HOST  Unable to find HOST
            } else if (code == "-1002") {
              // 非法的 URL  Illegal URL
            } else if (code == "-1001") {
              // 网络超时 Network timeout
            } else if (code == "-999") {
              // 请求被意外中断, 一般由用户进行取消操作导致 The interrupted request was usually caused by the user cancelling the operation
            } else if (code == "-21") {
              // 使用了重复的 challenge   Duplicate challenges are used
              // 检查获取 challenge 是否进行了缓存  Check if the fetch challenge is cached
            } else if (code == "-20") {
              // 尝试过多, 重新引导用户触发验证即可 Try too many times, lead the user to request verification again
            } else if (code == "-10") {
              // 预判断时被封禁, 不会再进行图形验证 Banned during pre-judgment, and no more image captcha verification
            } else if (code == "-2") {
              // Dart 调用异常 Call exception
            } else if (code == "-1") {
              // Gt3RegisterData 参数不合法  Parameter is invalid
            } else {
              // 更多错误码参考开发文档 More error codes refer to the development document
              // https://docs.geetest.com/sensebot/apirefer/errorcode/ios
            }
          }
        });
    captcha.startCaptcha(registerData);
  }

  // app端密码登录
  void loginByPassword() async {
    String username = usernameTextController.text;
    String password = passwordTextController.text;
    if (username.isEmpty || password.isEmpty) {
      SmartDialog.showToast('用户名或密码不能为空');
      return;
    }
    // if ((passwordFormKey.currentState as FormState).validate()) {
    var webKeyRes = await LoginHttp.getWebKey();
    print(webKeyRes);
    if (!webKeyRes['status']) {
      SmartDialog.showToast(webKeyRes['msg']);
      return;
    }
    String salt = webKeyRes['data']['hash'];
    String key = webKeyRes['data']['key'];
    print(key);
    var res = await LoginHttp.loginByPwd(
      username: username,
      password: password,
      key: key,
      salt: salt,
      gee_validate: captchaData.validate,
      gee_seccode: captchaData.seccode,
      gee_challenge: captchaData.geetest?.challenge,
      recaptcha_token: captchaData.token,
    );
    print(res);
    if (res['status']) {
      var data = res['data'];
      for (var key in data.keys) {
        print('$key: ${data[key]}');
      }
      if (data == null) {
        SmartDialog.showToast('登录异常，接口未返回数据：${res["msg"]}');
        return;
      }
      if (data['token_info'] == null) {
        SmartDialog.showToast('登录异常，接口未返回token信息，${res["msg"]}，\n $data');
        return;
      }
      if (data['cookie_info'] == null) {
        SmartDialog.showToast('登录异常，接口未返回cookie信息，${res["msg"]}，\n $data');
        return;
      }
      SmartDialog.showToast('正在保存身份信息');
      await afterLoginByApp(data['token_info'], data['cookie_info']);
      Get.back();
    } else {
      // handle login result
      switch (res['code']) {
        case 0:
          // login success
          break;
        case -105:
          String captureUrl = res['data']['url'];
          Uri captureUri = Uri.parse(captureUrl);
          captchaData.token = captureUri.queryParameters['recaptcha_token']!;
          String geeGt = captureUri.queryParameters['gee_gt']!;
          String geeChallenge = captureUri.queryParameters['gee_challenge']!;

          getCaptcha(geeGt, geeChallenge, () {
            loginByPassword();
          });
          break;
        default:
          SmartDialog.showToast(res['msg']);
          // login failed
          break;
      }
    }
    // }
  }

  // 短信验证码登录
  void loginBySmsCode() async {
    if (telTextController.text.isEmpty) {
      SmartDialog.showToast('手机号不能为空');
      return;
    }
    if (captchaKey.isEmpty) {
      SmartDialog.showToast('请先点击获取验证码');
      return;
    }
    if (smsCodeTextController.text.isEmpty) {
      SmartDialog.showToast('验证码不能为空');
      return;
    }
    if (DateTime.now().millisecondsSinceEpoch - smsSendTimestamp >
        1000 * 60 * 5) {
      SmartDialog.showToast('验证码已过期，请重新获取');
      return;
    }
    var webKeyRes = await LoginHttp.getWebKey();
    if (!webKeyRes['status']) {
      SmartDialog.showToast(webKeyRes['msg']);
      return;
    }
    String key = webKeyRes['data']['key'];
    var res = await LoginHttp.loginBySms(
      tel: telTextController.text,
      code: smsCodeTextController.text,
      captchaKey: captchaKey,
      cid: selectedCountryCodeId['country_id'],
      key: key,
    );
    print(res);
    if (res['status']) {
      SmartDialog.showToast('登录成功');
      var data = res['data'];
      for (var key in data.keys) {
        print('$key: ${data[key]}');
      }
      await afterLoginByApp(data['token_info'], data['cookie_info']);
      Get.back();
    } else {
      SmartDialog.showToast(res['msg']);
    }
  }

  // app端验证码
  void sendSmsCode() async {
    if (telTextController.text.isEmpty) {
      SmartDialog.showToast('手机号不能为空');
      return;
    }
    // String? guestId;
    // var webKeyRes = await LoginHttp.getWebKey();
    // if (!webKeyRes['status']) {
    //   SmartDialog.showToast(webKeyRes['msg']);
    // } else {
    //   String key = webKeyRes['data']['key'];
    //   var guestIdRes = await LoginHttp.getGuestId(key);
    //   if (!guestIdRes['status']) {
    //     SmartDialog.showToast(guestIdRes['msg']);
    //   } else {
    //     guestId = guestIdRes['data']['guest_id'];
    //   }
    // }

    var res = await LoginHttp.sendSmsCode(
      tel: telTextController.text,
      cid: selectedCountryCodeId['country_id'],
      // deviceTouristId: guestId,
      gee_validate: captchaData.validate,
      gee_seccode: captchaData.seccode,
      gee_challenge: captchaData.geetest?.challenge,
      recaptcha_token: captchaData.token,
    );
    print(res);
    if (res['status']) {
      SmartDialog.showToast('发送成功');
      smsSendTimestamp = DateTime.now().millisecondsSinceEpoch;
      smsSendCooldown.value = 60;
      captchaKey = res['data']['captcha_key'];
      smsSendCooldownTimer = Timer.periodic(Duration(seconds: 1), (timer) {
        smsSendCooldown.value = 60 - timer.tick;
        if (smsSendCooldown <= 0) {
          smsSendCooldownTimer?.cancel();
          smsSendCooldown.value = 0;
        }
      });
    } else {
      // handle login result
      switch (res['code']) {
        case 0:
        case -105:
          String captureUrl = res['data']['recaptcha_url'];
          Uri captureUri = Uri.parse(captureUrl);
          captchaData.token = captureUri.queryParameters['recaptcha_token']!;
          String geeGt = captureUri.queryParameters['gee_gt']!;
          String geeChallenge = captureUri.queryParameters['gee_challenge']!;
          getCaptcha(geeGt, geeChallenge, () {
            sendSmsCode();
          });
          break;
        default:
          SmartDialog.showToast(res['msg']);
          // login failed
          break;
      }
    }
  }
}

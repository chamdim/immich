import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart';
import 'package:immich_mobile/domain/interfaces/store.interface.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/presentation/router/router.dart';
import 'package:immich_mobile/service_locator.dart';
import 'package:immich_mobile/utils/constants/globals.dart';
import 'package:immich_mobile/utils/mixins/log_context.mixin.dart';
import 'package:openapi/api.dart';

@immutable
class ImmichApiClientData {
  final String endpoint;
  final Map<String, String> headersMap;

  const ImmichApiClientData({required this.endpoint, required this.headersMap});
}

class ImmichApiClient extends ApiClient with LogContext {
  ImmichApiClient({required String endpoint}) : super(basePath: endpoint);

  /// Used to recreate the client in Isolates
  ImmichApiClientData get clientData =>
      ImmichApiClientData(endpoint: basePath, headersMap: defaultHeaderMap);

  Future<void> init({String? accessToken}) async {
    final token =
        accessToken ?? (await di<IStoreRepository>().get(StoreKey.accessToken));

    if (token != null) {
      addDefaultHeader(kImmichHeaderAuthKey, token);
    }

    final deviceInfo = DeviceInfoPlugin();
    final String deviceModel;
    if (Platform.isIOS) {
      deviceModel = (await deviceInfo.iosInfo).utsname.machine;
    } else {
      deviceModel = (await deviceInfo.androidInfo).model;
    }

    addDefaultHeader(kImmichHeaderDeviceModel, deviceModel);
    addDefaultHeader(kImmichHeaderDeviceType, Platform.operatingSystem);
  }

  factory ImmichApiClient.clientData(ImmichApiClientData data) {
    final client = ImmichApiClient(endpoint: data.endpoint);

    for (final entry in data.headersMap.entries) {
      client.addDefaultHeader(entry.key, entry.value);
    }
    return client;
  }

  @override
  Future<Response> invokeAPI(
    String path,
    String method,
    List<QueryParam> queryParams,
    Object? body,
    Map<String, String> headerParams,
    Map<String, String> formParams,
    String? contentType,
  ) async {
    final res = await super.invokeAPI(
      path,
      method,
      queryParams,
      body,
      headerParams,
      formParams,
      contentType,
    );

    if (res.statusCode == HttpStatus.unauthorized) {
      log.severe("Token invalid. Redirecting to login route");
      await di<AppRouter>().replaceAll([const LoginRoute()]);
      throw ApiException(res.statusCode, "Unauthorized");
    }

    return res;
  }

  // ignore: avoid-dynamic
  static dynamic _patchDto(dynamic value, String targetType) {
    switch (targetType) {
      case 'UserPreferencesResponseDto':
        if (value is Map) {
          if (value['rating'] == null) {
            value['rating'] = RatingResponse().toJson();
          }
        }
    }
  }

  // ignore: avoid-dynamic
  static dynamic fromJson(
    // ignore: avoid-dynamic
    dynamic value,
    String targetType, {
    bool growable = false,
  }) {
    _patchDto(value, targetType);
    return ApiClient.fromJson(value, targetType, growable: growable);
  }

  @override
  // ignore: avoid-dynamic
  Future<dynamic> deserializeAsync(
    String value,
    String targetType, {
    bool growable = false,
  }) =>
      deserialize(value, targetType, growable: growable);

  @override
  // ignore: avoid-dynamic
  Future<dynamic> deserialize(
    String value,
    String targetType, {
    bool growable = false,
  }) async {
    targetType = targetType.replaceAll(' ', '');
    return targetType == 'String'
        ? value
        : fromJson(
            await compute((String j) => json.decode(j), value),
            targetType,
            growable: growable,
          );
  }

  UsersApi getUsersApi() => UsersApi(this);
  ServerApi getServerApi() => ServerApi(this);
  AuthenticationApi getAuthenticationApi() => AuthenticationApi(this);
  OAuthApi getOAuthApi() => OAuthApi(this);
  SyncApi getSyncApi() => SyncApi(this);
}
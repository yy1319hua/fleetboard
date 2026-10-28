import 'package:freezed_annotation/freezed_annotation.dart';

part 'release_info.freezed.dart';
part 'release_info.g.dart';

/// GitHub Release 资产：GET /repos/{owner}/{repo}/releases/latest → assets[]。
@freezed
class ReleaseAsset with _$ReleaseAsset {
  const factory ReleaseAsset({
    required String name,
    @JsonKey(name: 'browser_download_url') required String downloadUrl,
    required int size,
  }) = _ReleaseAsset;

  factory ReleaseAsset.fromJson(Map<String, dynamic> json) =>
      _$ReleaseAssetFromJson(json);
}

/// GitHub Release 元信息（latest）。
@freezed
class ReleaseInfo with _$ReleaseInfo {
  const factory ReleaseInfo({
    @JsonKey(name: 'tag_name') required String tagName,
    @JsonKey(name: 'html_url') required String htmlUrl,
    required String name,
    String? body,
    @Default(<ReleaseAsset>[]) List<ReleaseAsset> assets,
  }) = _ReleaseInfo;

  factory ReleaseInfo.fromJson(Map<String, dynamic> json) =>
      _$ReleaseInfoFromJson(json);
}

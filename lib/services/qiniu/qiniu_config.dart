/// Personal configuration. Credentials must only be persisted in secure storage.
class QiniuConfig {
  final String accessKey, secretKey, bucket, region, downloadDomain, prefix;
  final bool privateBucket;
  const QiniuConfig(
      {required this.accessKey,
      required this.secretKey,
      required this.bucket,
      this.region = '',
      this.downloadDomain = '',
      this.prefix = '',
      this.privateBucket = true});

  static const regions = {
    '': '自动发现',
    'z0': '华东 · 浙江',
    'cn-east-2': '华东 · 浙江 2',
    'z1': '华北 · 河北',
    'z2': '华南 · 广东',
    'na0': '北美 · 洛杉矶',
    'as0': '亚太 · 新加坡',
    'ap-southeast-2': '亚太 · 河内',
    'ap-southeast-3': '亚太 · 胡志明',
  };

  String? validationError({bool forDownload = false}) {
    if (accessKey.trim().isEmpty || secretKey.trim().isEmpty) {
      return '请填写 AccessKey 和 SecretKey';
    }
    if (RegExp(r'\s').hasMatch(accessKey) ||
        RegExp(r'\s').hasMatch(secretKey)) {
      return 'Key 中不能包含空白字符';
    }
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$').hasMatch(bucket)) {
      return '请填写有效的 Bucket 名称';
    }
    if (!regions.containsKey(region)) return '请选择支持的存储区域';
    if (forDownload && downloadDomain.isEmpty) return '请先在七牛云配置中填写下载域名';
    if (downloadDomain.isNotEmpty) {
      final uri = Uri.tryParse(downloadDomain);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          (uri.path.isNotEmpty && uri.path != '/')) {
        return '下载域名需为 HTTPS 域名，不含路径、账号或查询参数';
      }
    }
    if (utf8Length('$bucket:$prefix') > 700 || prefix.contains('\u0000')) {
      return '路径前缀过长或含无效字符';
    }
    return null;
  }

  Map<String, Object> publicJson() => {
        'bucket': bucket,
        'region': region,
        'downloadDomain': downloadDomain,
        'prefix': prefix,
        'privateBucket': privateBucket
      };
  Map<String, Object> secureJson() => {
        ...publicJson(),
        'accessKey': accessKey,
        'secretKey': secretKey,
        'version': 1
      };
  factory QiniuConfig.fromJson(Map<String, dynamic> json) => QiniuConfig(
      accessKey: json['accessKey'] as String,
      secretKey: json['secretKey'] as String,
      bucket: json['bucket'] as String,
      region: json['region'] as String? ?? '',
      downloadDomain: json['downloadDomain'] as String? ?? '',
      prefix: json['prefix'] as String? ?? '',
      privateBucket: json['privateBucket'] as bool? ?? true);
}

// Avoid retaining an encoder or secret-bearing diagnostic representation.
int utf8Length(String value) => value.runes.fold(
    0,
    (n, r) =>
        n +
        (r <= 0x7f
            ? 1
            : r <= 0x7ff
                ? 2
                : r <= 0xffff
                    ? 3
                    : 4));

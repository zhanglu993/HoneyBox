/// RTL8762D APP bank is 400 KiB, matching the layout validated on S200.
/// Assumes other 8762D projects use the same bank; override with a profile
/// or a device-reported capacity.
const Map<int, int> genericAppBankSizeByIcType = {9: 0x64000};

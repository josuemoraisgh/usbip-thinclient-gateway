import 'package:flutter_test/flutter_test.dart';
import 'package:usbip_monitor/main.dart';

void main() {
  test('AuditEntry stores USB/IP audit data', () {
    const entry = AuditEntry(
      timestamp: '2026-04-24 10:00:00',
      station: 'thinclient-01',
      hostIp: '192.168.100.31',
      busid: '1-1',
      vid: '303a',
      pid: '1001',
      description: 'Espressif USB Serial/JTAG',
      comPort: 'COM5',
    );

    expect(entry.station, 'thinclient-01');
    expect(entry.hostIp, '192.168.100.31');
    expect(entry.busid, '1-1');
    expect(entry.vid, '303a');
    expect(entry.pid, '1001');
    expect(entry.comPort, 'COM5');
  });
}

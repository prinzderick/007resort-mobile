import '../util/json.dart';

/// Waiter-only service flow (API docs/WAITER_ONLY_FLOW.md): a facility with `serviceFlow = WAITER_ONLY` has no kitchen/bar
/// screen and no cashier; waiters send, serve and take payment themselves.

class TabOrderItem {
  const TabOrderItem({
    required this.id,
    required this.number,
    required this.status,
    required this.total,
    required this.paid,
    required this.balance,
    required this.canPay,
    this.lines = const [],
    this.createdAt,
    this.ownerStaffId,
  });
  factory TabOrderItem.fromJson(Json j) => TabOrderItem(
    id: j.str('id'),
    number: j.str('number'),
    status: j.str('status'),
    total: j.str('total', '0'),
    paid: j.str('paid', '0'),
    balance: j.str('balance', '0'),
    canPay: j.boolOr('canPay'),
    lines: [
      for (final l in j.list('lines'))
        '${l.intOr('quantity', 1)} x ${l.str('name')}',
    ],
    createdAt: j.date('createdAt'),
    ownerStaffId: j.strOrNull('ownerStaffId'),
  );
  final String id;
  final String number;
  final String status;
  final String total;
  final String paid;
  final String balance;
  final bool canPay;
  final List<String> lines;
  final DateTime? createdAt;
  final String? ownerStaffId;
}

/// One unpaid tab (or a lone order): what a waiter pays in one go.
class TabGroup {
  const TabGroup({
    required this.key,
    required this.label,
    required this.ownerStaffId,
    required this.ownerName,
    required this.orders,
    required this.balance,
    required this.allServed,
    required this.handoverPending,
    this.tabId,
    this.oldestAt,
  });
  factory TabGroup.fromJson(Json j) {
    final table = j.strOrNull('tableLabel');
    final customer = j.strOrNull('customerName');
    final orders = j.list('orders').map(TabOrderItem.fromJson).toList();
    final label = [
      table,
      customer,
    ].whereType<String>().where((s) => s.isNotEmpty).join(' - ');
    return TabGroup(
      key: j.str('key'),
      tabId: j.strOrNull('tabId'),
      label: label.isNotEmpty
          ? label
          : (orders.isNotEmpty ? orders.first.number : 'Order'),
      ownerStaffId: j.str('ownerStaffId'),
      ownerName: j.strOrNull('ownerName') ?? '',
      orders: orders,
      balance: j.str('balance', '0'),
      allServed: j.boolOr('allServed'),
      handoverPending: j.boolOr('handoverPending'),
      oldestAt: j.date('oldestAt'),
    );
  }
  final String key;
  final String? tabId;
  final String label;
  final String ownerStaffId;
  final String ownerName;
  final List<TabOrderItem> orders;
  final String balance;
  final bool allServed;
  final bool handoverPending;
  final DateTime? oldestAt;

  List<String> get orderIds => [for (final o in orders) o.id];
}

class WaiterTotals {
  const WaiterTotals({
    required this.staffId,
    required this.name,
    required this.tabs,
    required this.orders,
    required this.balance,
  });
  factory WaiterTotals.fromJson(Json j) => WaiterTotals(
    staffId: j.str('staffId'),
    name: j.str('name'),
    tabs: j.intOr('tabs'),
    orders: j.intOr('orders'),
    balance: j.str('balance', '0'),
  );
  final String staffId;
  final String name;
  final int tabs;
  final int orders;
  final String balance;
}

class OpenItems {
  const OpenItems({
    this.groups = const [],
    this.waiters = const [],
    this.all = false,
    this.balance = '0',
  });
  factory OpenItems.fromJson(Json j) => OpenItems(
    groups: j.list('groups').map(TabGroup.fromJson).toList(),
    waiters: j.list('waiters').map(WaiterTotals.fromJson).toList(),
    all: j.str('scope') == 'ALL',
    balance: j.obj('totals').str('balance', '0'),
  );
  final List<TabGroup> groups;
  final List<WaiterTotals> waiters;

  /// True for a supervisor/manager view of everybody's tabs.
  final bool all;
  final String balance;
}

class HandoverItem {
  const HandoverItem({
    required this.orderId,
    required this.number,
    this.tableLabel,
    this.customerName,
    this.balance = '0',
  });
  factory HandoverItem.fromJson(Json j) => HandoverItem(
    orderId: j.str('orderId'),
    number: j.str('number'),
    tableLabel: j.strOrNull('tableLabel'),
    customerName: j.strOrNull('customerName'),
    balance: j.str('balance', '0'),
  );
  final String orderId;
  final String number;
  final String? tableLabel;
  final String? customerName;
  final String balance;
}

class TabHandover {
  const TabHandover({
    required this.id,
    required this.status,
    required this.fromStaffId,
    required this.fromName,
    required this.toStaffId,
    required this.toName,
    required this.items,
    required this.balance,
    this.note,
    this.expiresAt,
  });
  factory TabHandover.fromJson(Json j) => TabHandover(
    id: j.str('id'),
    status: j.str('status'),
    fromStaffId: j.str('fromStaffId'),
    fromName: j.str('fromName'),
    toStaffId: j.str('toStaffId'),
    toName: j.str('toName'),
    items: j.list('items').map(HandoverItem.fromJson).toList(),
    balance: j.str('balance', '0'),
    note: j.strOrNull('note'),
    expiresAt: j.date('expiresAt'),
  );
  final String id;
  final String status;
  final String fromStaffId;
  final String fromName;
  final String toStaffId;
  final String toName;
  final List<HandoverItem> items;
  final String balance;
  final String? note;
  final DateTime? expiresAt;

  bool get pending => status == 'PENDING';
}

class Colleague {
  const Colleague({required this.staffId, required this.name});
  factory Colleague.fromJson(Json j) =>
      Colleague(staffId: j.str('staffId'), name: j.str('name'));
  final String staffId;
  final String name;
}

/// One way the customer paid.
class PayTender {
  const PayTender({
    required this.type,
    required this.amount,
    this.reference,
    this.tendered,
  });
  final String type; // CASH | POS_TERMINAL | TRANSFER | CARD
  final String amount;
  final String? reference;
  final String? tendered;

  Map<String, dynamic> toApi() => {
    'tenderType': type,
    'amount': amount,
    if (reference != null && reference!.isNotEmpty) 'reference': reference,
    if (tendered != null && tendered!.isNotEmpty) 'tendered': tendered,
  };
}

class WaiterPayResult {
  const WaiterPayResult({
    required this.receiptId,
    required this.changeDue,
    required this.closedTabs,
  });
  factory WaiterPayResult.fromJson(Json j) => WaiterPayResult(
    receiptId: j.str('receiptId'),
    changeDue: j.str('changeDue', '0'),
    closedTabs: (j['closedTabIds'] is List)
        ? (j['closedTabIds'] as List).length
        : 0,
  );
  final String receiptId;
  final String changeDue;
  final int closedTabs;
}

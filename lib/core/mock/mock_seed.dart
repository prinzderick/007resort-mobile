import '../models/models.dart';

/// Seeded demo data for the built-in Mock API. Prices are decimal strings
/// exactly as a real server would send them.

class MockStaff {
  const MockStaff({
    required this.id,
    required this.username,
    required this.name,
    required this.staffNumber,
    required this.pin,
    required this.nfcUid,
    required this.permissions,
  });
  final String id;
  final String username;
  final String name;
  final String staffNumber;
  final String pin;
  final String nfcUid;
  final Set<String> permissions;

  Staff toStaff() => Staff(
    id: id,
    name: name,
    staffNumber: staffNumber,
    permissions: permissions,
  );
}

/// Waiter bundle. Note `*.execute` without `*.approve`: the waiter may
/// REQUEST a void/discount but a supervisor must approve (spec 06 §3).
const _waiter = {
  'order.view',
  'order.create',
  'order.line.add',
  'order.line.remove_unsent',
  'order.send',
  'order.serve',
  'tab.open',
  'tab.view_own_facility',
  'order.void.execute',
  'order.discount.execute',
};

/// Trainee bundle: can take/send orders but holds neither void nor discount
/// permission, so the UI hides those direct actions and offers the supervisor
/// PIN route instead.
const _trainee = {
  'order.view',
  'order.create',
  'order.line.add',
  'order.line.remove_unsent',
  'order.send',
  'order.serve',
  'tab.open',
  'tab.view_own_facility',
};

final List<MockStaff> mockStaff = [
  const MockStaff(
    id: '11111111-0000-4000-8000-000000000001',
    username: 'amaka',
    name: 'Amaka Obi',
    staffNumber: '1001',
    pin: '1234',
    nfcUid: '04A1B2C3',
    permissions: _waiter,
  ),
  const MockStaff(
    id: '11111111-0000-4000-8000-000000000002',
    username: 'chidi',
    name: 'Chidi Eze (trainee)',
    staffNumber: '1002',
    pin: '2345',
    nfcUid: '04A1B2C4',
    permissions: _trainee,
  ),
  const MockStaff(
    id: '11111111-0000-4000-8000-000000000003',
    username: 'ngozi',
    name: 'Ngozi Okafor (Supervisor)',
    staffNumber: '2001',
    pin: '9999',
    nfcUid: '04D4E5F6',
    permissions: {
      ..._waiter,
      'prep_ticket.view',
      'order.void.approve',
      'order.discount.approve',
      'order.price_override.approve',
      'order.comp.approve',
    },
  ),
  const MockStaff(
    id: '11111111-0000-4000-8000-000000000004',
    username: 'sports1',
    name: 'Sports Operator',
    staffNumber: '3001',
    pin: '5555',
    nfcUid: '04F0F0F1',
    permissions: {'ticket.view', 'ticket.redeem', 'ticket.release'},
  ),
];

/// Registration codes -> device kind / home facility (mock only).
class MockEnrolment {
  const MockEnrolment(this.kind, this.homeFacilityId);
  final String kind;
  final String? homeFacilityId;
}

const mockEnrolmentCodes = <String, MockEnrolment>{
  // Like the real demo seed: the shared waiter pool is homed at Reception.
  'ATT-2026': MockEnrolment('MOBILE_TABLET', 'f-reception'),
  'SUP-2026': MockEnrolment('MOBILE_TABLET', 'f-restaurant'),
  'ENT-2026': MockEnrolment('ENTRANCE_SCANNER', 'f-sports-entrance'),
  'STO-2026': MockEnrolment('MOBILE_TABLET', 'f-sports-store'),
};

const mockFacilities = <Facility>[
  Facility(
    id: 'f-restaurant',
    name: 'Restaurant',
    kind: 'RESTAURANT',
    code: 'RESTAURANT',
  ),
  Facility(
    id: 'f-indoor',
    name: 'Indoor Club',
    kind: 'INDOOR_CLUB',
    code: 'INDOOR_CLUB',
  ),
  Facility(id: 'f-poolbar', name: 'Pool Bar', kind: 'BAR', code: 'POOL_BAR'),
  Facility(
    id: 'f-bush',
    name: 'Bush Bar / Event Centre',
    kind: 'BAR',
    code: 'BUSH_BAR',
  ),
  Facility(
    id: 'f-sports-entrance',
    name: 'Sports Arena',
    kind: 'SPORTS',
    code: 'SPORTS_ARENA',
  ),
  Facility(
    id: 'f-sports-store',
    name: 'Sports Store',
    kind: 'STORE',
    code: 'SPORTS_STORE',
  ),
  Facility(
    id: 'f-reception',
    name: 'Main Reception',
    kind: 'RECEPTION',
    code: 'RECEPTION',
  ),
];

/// Facilities a shared waiter tablet may be checked out to.
const mockCheckoutFacilityIds = [
  'f-restaurant',
  'f-indoor',
  'f-poolbar',
  'f-bush',
];

/// Facilities that have no dining tables (customers/tabs only).
const mockNoTableFacilities = {'f-poolbar', 'f-bush'};

const mockFoodCategories = <Category>[
  Category(id: 'c-starters', name: 'Starters'),
  Category(id: 'c-mains', name: 'Mains'),
  Category(id: 'c-drinks', name: 'Drinks'),
];

const _doneness = ModifierGroup(
  id: 'g-doneness',
  name: 'Doneness',
  minSelect: 1,
  maxSelect: 1,
  options: [
    ModifierOption(id: 'o-rare', name: 'Rare'),
    ModifierOption(id: 'o-medium', name: 'Medium'),
    ModifierOption(id: 'o-well', name: 'Well done'),
  ],
);
const _extras = ModifierGroup(
  id: 'g-extras',
  name: 'Extras',
  minSelect: 0,
  maxSelect: 3,
  options: [
    ModifierOption(
      id: 'o-plantain',
      name: 'Fried plantain',
      priceDelta: '500.00',
    ),
    ModifierOption(id: 'o-egg', name: 'Fried egg', priceDelta: '300.00'),
    ModifierOption(
      id: 'o-chili',
      name: 'Extra pepper sauce',
      priceDelta: '0.00',
    ),
  ],
);

const mockFoodProducts = <Product>[
  Product(
    id: 'p-suya',
    name: 'Beef Suya',
    categoryId: 'c-starters',
    price: '3500.00',
  ),
  Product(
    id: 'p-pepper-soup',
    name: 'Goat Pepper Soup',
    categoryId: 'c-starters',
    price: '4500.00',
  ),
  Product(
    id: 'p-spring',
    name: 'Spring Rolls',
    categoryId: 'c-starters',
    price: '3000.00',
  ),
  Product(
    id: 'p-steak',
    name: 'Grilled Steak',
    categoryId: 'c-mains',
    price: '12500.00',
    modifierGroups: [_doneness, _extras],
  ),
  Product(
    id: 'p-jollof',
    name: 'Jollof Rice & Chicken',
    categoryId: 'c-mains',
    price: '6500.00',
    modifierGroups: [_extras],
  ),
  Product(
    id: 'p-egusi',
    name: 'Egusi & Pounded Yam',
    categoryId: 'c-mains',
    price: '7500.00',
  ),
  Product(
    id: 'p-fish',
    name: 'Grilled Tilapia',
    categoryId: 'c-mains',
    price: '9500.00',
  ),
  Product(
    id: 'p-water',
    name: 'Bottled Water',
    categoryId: 'c-drinks',
    price: '500.00',
  ),
  Product(
    id: 'p-coke',
    name: 'Soft Drink',
    categoryId: 'c-drinks',
    price: '800.00',
  ),
  Product(id: 'p-zobo', name: 'Zobo', categoryId: 'c-drinks', price: '1200.00'),
  Product(
    id: 'p-sold-out',
    name: 'Lobster Thermidor',
    categoryId: 'c-mains',
    price: '25000.00',
    available: false,
  ),
];

const mockBarCategories = <Category>[
  Category(id: 'c-beer', name: 'Beers'),
  Category(id: 'c-spirits', name: 'Spirits'),
  Category(id: 'c-soft', name: 'Soft Drinks'),
  Category(id: 'c-snacks', name: 'Snacks'),
];

const mockBarProducts = <Product>[
  Product(
    id: 'b-star',
    name: 'Star Lager 60cl',
    categoryId: 'c-beer',
    price: '1500.00',
  ),
  Product(
    id: 'b-heineken',
    name: 'Heineken',
    categoryId: 'c-beer',
    price: '2000.00',
  ),
  Product(
    id: 'b-guinness',
    name: 'Guinness Stout',
    categoryId: 'c-beer',
    price: '1800.00',
  ),
  Product(
    id: 'b-hennessy',
    name: 'Hennessy VS (shot)',
    categoryId: 'c-spirits',
    price: '4000.00',
    modifierGroups: [
      ModifierGroup(
        id: 'g-mixer',
        name: 'Mixer',
        maxSelect: 1,
        options: [
          ModifierOption(id: 'o-neat', name: 'Neat'),
          ModifierOption(id: 'o-ice', name: 'On ice'),
          ModifierOption(id: 'o-coke', name: 'With cola', priceDelta: '300.00'),
        ],
      ),
    ],
  ),
  Product(
    id: 'b-vodka',
    name: 'Vodka (shot)',
    categoryId: 'c-spirits',
    price: '2500.00',
  ),
  Product(id: 'b-fanta', name: 'Fanta', categoryId: 'c-soft', price: '800.00'),
  Product(
    id: 'b-water',
    name: 'Bottled Water',
    categoryId: 'c-soft',
    price: '500.00',
  ),
  Product(
    id: 'b-nuts',
    name: 'Peanuts',
    categoryId: 'c-snacks',
    price: '1000.00',
  ),
  Product(
    id: 'b-chips',
    name: 'Plantain Chips',
    categoryId: 'c-snacks',
    price: '1500.00',
  ),
];

/// Drinks/bar products are routed to a bar station (faster progression).
bool isBarProduct(String productId) =>
    productId.startsWith('b-') ||
    productId == 'p-water' ||
    productId == 'p-coke' ||
    productId == 'p-zobo';

/// Demo QR payloads shown as chips on Sports screens in mock mode.
const mockDemoCodes = <String, String>{
  'R007-DEMO-VALID-1': 'Valid ticket (adult)',
  'R007-DEMO-VALID-2': 'Valid ticket (child)',
  'R007-DEMO-USED': 'Already used',
  'R007-DEMO-EXPIRED': 'Expired',
  'R007-DEMO-WRONG': 'Wrong facility (Pool)',
  'R007-DEMO-FUTURE': 'Not yet valid',
  'R007-DEMO-CANCELLED': 'Cancelled',
  'R007-DEMO-STORE-1': 'Court + 2 rackets + water',
  'R007-DEMO-STORE-2': 'Football hire',
};

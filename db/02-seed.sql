-- Sample data so the bot works out of the box. Replace with the real restaurant's details
-- (edit here before the first `docker compose up`, or change the rows later with SQL).

INSERT INTO restaurant (name, currency, delivery_fee, min_order, opening_hours, delivery_areas, address, phone)
VALUES ('Sample Restaurant', 'Rs', 150, 500,
        'Every day, 12:00 pm to 12:00 am',
        'Within about 5 km of the restaurant',
        'Main Boulevard, Your City',
        '0300-0000000');

INSERT INTO menu_items (category, name, description, price, sort_order) VALUES
    ('Starters', 'Chicken Samosa (2 pcs)',  'Crispy pastry, spiced chicken filling',       180, 10),
    ('Starters', 'Dahi Bhalla',             'Lentil dumplings in yogurt with chutneys',     250, 11),
    ('BBQ',      'Chicken Tikka (leg)',     'Charcoal grilled, served with chutney',        450, 20),
    ('BBQ',      'Seekh Kabab (4 pcs)',     'Minced beef kababs',                           650, 21),
    ('BBQ',      'Malai Boti (8 pcs)',      'Creamy boneless chicken',                      750, 22),
    ('Karahi',   'Chicken Karahi (half)',   'Serves 2-3',                                  1100, 30),
    ('Karahi',   'Chicken Karahi (full)',   'Serves 4-5',                                  2000, 31),
    ('Karahi',   'Mutton Karahi (half)',    'Serves 2-3',                                  2200, 32),
    ('Rice',     'Chicken Biryani',         'Single serving with raita',                    450, 40),
    ('Rice',     'Beef Pulao',              'Single serving with raita',                    550, 41),
    ('Burgers',  'Zinger Burger',           'Crispy chicken fillet, fries on the side',     550, 50),
    ('Burgers',  'Beef Burger',             'Grilled beef patty, cheese, fries on the side', 650, 51),
    ('Breads',   'Naan',                    '',                                              40, 60),
    ('Breads',   'Garlic Naan',             '',                                              90, 61),
    ('Breads',   'Roti',                    '',                                              25, 62),
    ('Drinks',   'Soft Drink (345 ml)',     'Ask which flavours are available',             120, 70),
    ('Drinks',   'Mineral Water (500 ml)',  '',                                              80, 71),
    ('Drinks',   'Mint Margarita',          '',                                             280, 72),
    ('Dessert',  'Kheer',                   'Rice pudding',                                 220, 80),
    ('Dessert',  'Gulab Jamun (2 pcs)',     '',                                             180, 81);

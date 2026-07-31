-- item_names.lua
-- Generation II item names by index (0-255), used for reading a wild
-- Pokemon's held item byte. Indices 0-242 verified directly against
-- Bulbapedia's "List of items by index number in Generation II".
-- Indices 243-255 (HMs + a couple of unused slots) are filled in from
-- standard HM ordering rather than independently re-verified - this is
-- fine in practice since no wild Pokemon in the base game holds an HM.
--
-- Index 0 means "no item held".

local M = {
    [0] = "(no item)",
    [1] = "Master Ball", [2] = "Ultra Ball", [3] = "BrightPowder", [4] = "Great Ball",
    [5] = "Poke Ball", [6] = "Teru-sama", [7] = "Bicycle", [8] = "Moon Stone",
    [9] = "Antidote", [10] = "Burn Heal", [11] = "Ice Heal", [12] = "Awakening",
    [13] = "Parlyz Heal", [14] = "Full Restore", [15] = "Max Potion", [16] = "Hyper Potion",
    [17] = "Super Potion", [18] = "Potion", [19] = "Escape Rope", [20] = "Repel",
    [21] = "Max Elixer", [22] = "Fire Stone", [23] = "Thunderstone", [24] = "Water Stone",
    [25] = "Teru-sama", [26] = "HP Up", [27] = "Protein", [28] = "Iron",
    [29] = "Carbos", [30] = "Lucky Punch", [31] = "Calcium", [32] = "Rare Candy",
    [33] = "X Accuracy", [34] = "Leaf Stone", [35] = "Metal Powder", [36] = "Nugget",
    [37] = "Poke Doll", [38] = "Full Heal", [39] = "Revive", [40] = "Max Revive",
    [41] = "Guard Spec.", [42] = "Super Repel", [43] = "Max Repel", [44] = "Dire Hit",
    [45] = "Teru-sama", [46] = "Fresh Water", [47] = "Soda Pop", [48] = "Lemonade",
    [49] = "X Attack", [50] = "Teru-sama", [51] = "X Defend", [52] = "X Speed",
    [53] = "X Special", [54] = "Coin Case", [55] = "Itemfinder", [56] = "Teru-sama",
    [57] = "Exp.Share", [58] = "Old Rod", [59] = "Good Rod", [60] = "Silver Leaf",
    [61] = "Super Rod", [62] = "PP Up", [63] = "Ether", [64] = "Max Ether",
    [65] = "Elixer", [66] = "Red Scale", [67] = "SecretPotion", [68] = "S.S. Ticket",
    [69] = "Mystery Egg", [70] = "Clear Bell", [71] = "Silver Wing", [72] = "Moomoo Milk",
    [73] = "Quick Claw", [74] = "PSNCureBerry", [75] = "Gold Leaf", [76] = "Soft Sand",
    [77] = "Sharp Beak", [78] = "PRZCureBerry", [79] = "Burnt Berry", [80] = "Ice Berry",
    [81] = "Poison Barb", [82] = "King's Rock", [83] = "Bitter Berry", [84] = "Mint Berry",
    [85] = "Red Apricorn", [86] = "TinyMushroom", [87] = "Big Mushroom", [88] = "SilverPowder",
    [89] = "Blu Apricorn", [90] = "Teru-sama", [91] = "Amulet Coin", [92] = "Ylw Apricorn",
    [93] = "Grn Apricorn", [94] = "Cleanse Tag", [95] = "Mystic Water", [96] = "TwistedSpoon",
    [97] = "Wht Apricorn", [98] = "Blackbelt", [99] = "Blk Apricorn", [100] = "Teru-sama",
    [101] = "Pnk Apricorn", [102] = "BlackGlasses", [103] = "SlowpokeTail", [104] = "Pink Bow",
    [105] = "Stick", [106] = "Smoke Ball", [107] = "NeverMeltIce", [108] = "Magnet",
    [109] = "MiracleBerry", [110] = "Pearl", [111] = "Big Pearl", [112] = "Everstone",
    [113] = "Spell Tag", [114] = "RageCandyBar", [115] = "GS Ball", [116] = "Blue Card",
    [117] = "Miracle Seed", [118] = "Thick Club", [119] = "Focus Band", [120] = "Teru-sama",
    [121] = "EnergyPowder", [122] = "Energy Root", [123] = "Heal Powder", [124] = "Revival Herb",
    [125] = "Hard Stone", [126] = "Lucky Egg", [127] = "Card Key", [128] = "Machine Part",
    [129] = "Egg Ticket", [130] = "Lost Item", [131] = "Stardust", [132] = "Star Piece",
    [133] = "Basement Key", [134] = "Pass", [135] = "Teru-sama", [136] = "Teru-sama",
    [137] = "Teru-sama", [138] = "Charcoal", [139] = "Berry Juice", [140] = "Scope Lens",
    [141] = "Teru-sama", [142] = "Teru-sama", [143] = "Metal Coat", [144] = "Dragon Fang",
    [145] = "Teru-sama", [146] = "Leftovers", [147] = "Teru-sama", [148] = "Teru-sama",
    [149] = "Teru-sama", [150] = "MysteryBerry", [151] = "Dragon Scale", [152] = "Berserk Gene",
    [153] = "Teru-sama", [154] = "Teru-sama", [155] = "Teru-sama", [156] = "Sacred Ash",
    [157] = "Heavy Ball", [158] = "Flower Mail", [159] = "Level Ball", [160] = "Lure Ball",
    [161] = "Fast Ball", [162] = "Teru-sama", [163] = "Light Ball", [164] = "Friend Ball",
    [165] = "Moon Ball", [166] = "Love Ball", [167] = "Normal Box", [168] = "Gorgeous Box",
    [169] = "Sun Stone", [170] = "Polkadot Bow", [171] = "Teru-sama", [172] = "Up-Grade",
    [173] = "Berry", [174] = "Gold Berry", [175] = "SquirtBottle", [176] = "Teru-sama",
    [177] = "Park Ball", [178] = "Rainbow Wing", [179] = "Teru-sama", [180] = "Brick Piece",
    [181] = "Surf Mail", [182] = "Litebluemail", [183] = "Portraitmail", [184] = "Lovely Mail",
    [185] = "Eon Mail", [186] = "Morph Mail", [187] = "Bluesky Mail", [188] = "Music Mail",
    [189] = "Mirage Mail", [190] = "Teru-sama",
    [191] = "TM01", [192] = "TM02", [193] = "TM03", [194] = "TM04", [195] = "TM04",
    [196] = "TM05", [197] = "TM06", [198] = "TM07", [199] = "TM08", [200] = "TM09",
    [201] = "TM10", [202] = "TM11", [203] = "TM12", [204] = "TM13", [205] = "TM14",
    [206] = "TM15", [207] = "TM16", [208] = "TM17", [209] = "TM18", [210] = "TM19",
    [211] = "TM20", [212] = "TM21", [213] = "TM22", [214] = "TM23", [215] = "TM24",
    [216] = "TM25", [217] = "TM26", [218] = "TM27", [219] = "TM28", [220] = "TM28",
    [221] = "TM29", [222] = "TM30", [223] = "TM31", [224] = "TM32", [225] = "TM33",
    [226] = "TM34", [227] = "TM35", [228] = "TM36", [229] = "TM37", [230] = "TM38",
    [231] = "TM39", [232] = "TM40", [233] = "TM41", [234] = "TM42", [235] = "TM43",
    [236] = "TM44", [237] = "TM45", [238] = "TM46", [239] = "TM47", [240] = "TM48",
    [241] = "TM49", [242] = "TM50",
    -- Not independently re-verified past this point (fetch got cut off) -
    -- standard Gen 2 HM ordering, irrelevant for held-item detection anyway.
    [243] = "HM01", [244] = "HM02", [245] = "HM03", [246] = "HM04", [247] = "HM05",
    [248] = "HM06", [249] = "HM07",
}

return M

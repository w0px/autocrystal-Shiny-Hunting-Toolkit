-- Originally written by M4_used_Rollout for Twitch Plays Pokemon

local bankSizes = {
    ROM = 0x4000,
    VRAM = 0x2000,
    SRAM = 0x2000,
    CartRAM = 0x2000, --a.k.a. SRAM
    WRAM = 0x1000
}

local knownRomBankAddresses = {
    Red = 0xFFB8,
    Blue = 0xFFB8,
    Yellow = 0xFFB8,
    Gold = 0xFF9F,
    Silver = 0xFF9F,
    Crystal = 0xFF9D,
    Pinball = 0xFFF8
}

local function LinearAddressToBank(linear, bankSize, noHomeBank)
    bankSize = bankSize or bankSizes.ROM
    local bank = math.floor(linear / bankSize)
    local address = linear % bankSize
    if bank > 0 and not noHomeBank then
        -- ROM and WRAM have a home bank (Bank 0)
        -- All switchable banks (Bank 1+) live after the home bank
        -- Add the bank size to the address to account for this
        address = address | bankSize
    end
    return address, bank
end

local function BankAddressToLinear(bank, address, bankSize)
    bankSize = bankSize or bankSizes.ROM
    return bank * bankSize | address % bankSize;
end

local function LinearAddressToBankString(linear, bankSize, noHomeBank)
    local address, bank = LinearAddressToBank(linear, bankSize, noHomeBank)
    return bizstring.hex(bank) .. ":" .. bizstring.hex(address)
end

local hROMBank = 0xFFFF -- use SetRomBankAddress to change this

local function CurrentROMBank()
    return memory.readbyte(hROMBank, "System Bus")
end

local function RegisterROMHook(romAddr, action, name, onRead)
    if not romAddr then return end
    event.unregisterbyname(name)
    local address, bank = LinearAddressToBank(romAddr)
    local execIfCorrectBank = function ()
        --print(name .. " Address " .. bizstring.hex(address) .. " Bank " .. bizstring.hex(bank) .. " Current Bank " .. CurrentROMBank() .. " hROMBank " .. bizstring.hex(hROMBank))
        if address < bankSizes.ROM or CurrentROMBank() == bank then
            --print(name)
            action()
        end
    end
    if onRead then
        event.onmemoryread(execIfCorrectBank, address, name)
    else
        event.onmemoryexecute(execIfCorrectBank, address, name)
    end
    --print("Registered " .. name .. " on " .. bizstring.hex(romAddr) .. " (" .. bizstring.hex(bank) .. ":" .. bizstring.hex(address) .. ")")
end

local function SetRomBankAddress(addr)
    hROMBank = knownRomBankAddresses[addr] or addr
    if type(hROMBank) ~= "number" then
        print("Unknown ROM Bank addr")
    end
end

return {
    LinearAddressToBankString = LinearAddressToBankString,
    LinearAddressToBank = LinearAddressToBank,
    BankAddressToLinear = BankAddressToLinear,
    RegisterROMHook = RegisterROMHook,
    RegisterDirectROMHook = RegisterDirectROMHook,
    CurrentROMBank = CurrentROMBank,
    SetRomBankAddress = SetRomBankAddress,
    BankSizes = bankSizes
}
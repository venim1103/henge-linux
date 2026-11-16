// SPDX-License-Identifier: GPL-3.0-or-later
// StikDebug / LLDB breakpoint handler for iOS 26/27 TXM dual-mapped JIT setup.
const CMD_DETACH = 0;
const CMD_PREPARE_REGION = 1;
const CMD_NEW_BREAKPOINTS = 2;

const commands = {
    [CMD_DETACH]: JIT26Detach,
    [CMD_PREPARE_REGION]: JIT26PrepareRegion,
    [CMD_NEW_BREAKPOINTS]: JIT26NewBreakpoints
};

const legacyCommands = {
    [0x68]: JIT26NewBreakpoints,
    [0x69]: JIT26HandleBrk0x69,
    [0xf00d]: JIT26HandleBrk0xf00d
};

let tid, x0, x1, x16, pc;
let detached = false;
let pid = get_pid();
log(`pid = ${pid}`);
let attachResponse = send_command(`vAttach;${pid.toString(16)}`);
log(`attach_response = ${attachResponse}`);

let totalBreakpoints = 0;
while (!detached) {
    totalBreakpoints++;
    log(`Handling breakpoint ${totalBreakpoints}`);

    let brkResponse = send_command(`c`);
    log(`brkResponse = ${brkResponse}`);

    let tmpMatch = /T[0-9a-f]+thread:(?<tid>[0-9a-f]+);/.exec(brkResponse);
    tid = tmpMatch ? tmpMatch.groups['tid'] : null;
    tmpMatch = /20:(?<reg>[0-9a-f]{16});/.exec(brkResponse);
    pc = tmpMatch ? tmpMatch.groups['reg'] : null;
    tmpMatch = /10:(?<reg>[0-9a-f]{16});/.exec(brkResponse);
    x16 = tmpMatch ? tmpMatch.groups['reg'] : null;
    if (!tid || !pc || !x16) {
        log(`Failed to extract registers: tid=${tid}, pc=${pc}, x16=${x16}`);
        continue;
    }
    pc = littleEndianHexStringToNumber(pc);
    x16 = littleEndianHexStringToNumber(x16);

    let instructionResponse = send_command(`m${pc.toString(16)},4`);
    let instrU32 = littleEndianHexToU32(instructionResponse);
    let brkImmediate = extractBrkImmediate(instrU32);
    if (legacyCommands[brkImmediate] !== undefined) {
        tmpMatch = /00:(?<reg>[0-9a-f]{16});/.exec(brkResponse);
        x0 = tmpMatch ? tmpMatch.groups['reg'] : null;
        tmpMatch = /01:(?<reg>[0-9a-f]{16});/.exec(brkResponse);
        x1 = tmpMatch ? tmpMatch.groups['reg'] : null;
        if (!x0 || !x1) {
            continue;
        }
        x0 = littleEndianHexStringToNumber(x0);
        x1 = littleEndianHexStringToNumber(x1);

        let pcPlus4 = numberToLittleEndianHexString(pc + 4n);
        send_command(`P20=${pcPlus4};thread:${tid};`);

        const command = legacyCommands[brkImmediate];
        command(brkResponse);
    }
}

function JIT26Detach() {
    send_command(`D`);
    detached = true;
}

function JIT26NewBreakpoints() {
    let memResponse = send_command(`m${x0.toString(16)},${x1}`);
    let scriptText = hexToAscii(memResponse);
    try {
        eval(scriptText);
    } catch (err) {
        log('Script failed:', err);
    }
}

function JIT26HandleBrk0x69() {
    send_command(`P0=E0000069;thread:${tid};`);
}

function JIT26HandleBrk0xf00d() {
    const command = commands[x16];
    if (command !== undefined) {
        command();
    }
}

function JIT26PrepareRegion() {
    if (x0 === 0n && x1 === 0n) {
        return;
    }
    let jitPageAddress = x0;
    if (x0 === 0n) {
        let requestRXResponse = send_command(`_M${x1.toString(16)},rx`);
        if (!requestRXResponse || requestRXResponse.length === 0) {
            return;
        }
        jitPageAddress = BigInt(`0x${requestRXResponse}`);
    }
    prepare_memory_region(jitPageAddress, x1);
    send_command(`P0=${numberToLittleEndianHexString(jitPageAddress)};thread:${tid};`);
}

function littleEndianHexStringToNumber(hexStr) {
    const bytes = [];
    for (let i = 0; i < hexStr.length; i += 2) {
        bytes.push(parseInt(hexStr.substr(i, 2), 16));
    }
    let num = 0n;
    for (let i = 4; i >= 0; i--) {
        num = (num << 8n) | BigInt(bytes[i]);
    }
    return num;
}

function numberToLittleEndianHexString(num) {
    const bytes = [];
    for (let i = 0; i < 5; i++) {
        bytes.push(Number(num & 0xFFn));
        num >>= 8n;
    }
    while (bytes.length < 8) {
        bytes.push(0);
    }
    return bytes.map(b => b.toString(16).padStart(2, '0')).join('');
}

function littleEndianHexToU32(hexStr) {
    return parseInt(hexStr.match(/../g).reverse().join(''), 16);
}

function extractBrkImmediate(u32) {
    return (u32 >> 5) & 0xFFFF;
}

function hexToAscii(hexStr) {
    let str = '';
    for (let i = 0; i < hexStr.length; i += 2) {
        const byte = parseInt(hexStr.substr(i, 2), 16);
        if (byte === 0) break;
        str += String.fromCharCode(byte);
    }
    return str;
}

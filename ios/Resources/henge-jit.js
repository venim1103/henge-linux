// SPDX-License-Identifier: GPL-3.0-or-later
// StikDebug / LLDB breakpoint handler for iOS 26/27 TXM dual-mapped JIT setup.
const CMD_DETACH = 0;
const CMD_PREPARE_REGION = 1;

const commands = {
    [CMD_DETACH]: JIT26Detach,
    [CMD_PREPARE_REGION]: JIT26PrepareRegion
};

const legacyCommands = {
    [0x69]: JIT26HandleBrk0x69,
    [0xf00d]: JIT26HandleBrk0xf00d
};

let tid, x0, x1, x16, pc;
let detached = false;
let pid = get_pid();
log(`pid = ${pid}`);
let attachResponse = send_command(`vAttach;${pid.toString(16)}`);
log(`attach_response = ${attachResponse}`);
if (!attachResponse || attachResponse.startsWith('E')) {
    detached = true;
}

let totalBreakpoints = 0;
while (!detached) {
    totalBreakpoints++;
    log(`Handling breakpoint ${totalBreakpoints}`);

    let brkResponse = send_command(`c`);
    log(`brkResponse = ${brkResponse}`);
    if (!brkResponse || brkResponse.startsWith('E') || brkResponse.startsWith('W') || brkResponse.startsWith('X')) {
        log(`Target exited or errored: ${brkResponse}`);
        break;
    }

    let tmpMatch = /T[0-9a-fA-F]+thread:(?<tid>[0-9a-fA-F]+);/.exec(brkResponse);
    tid = tmpMatch ? tmpMatch.groups['tid'] : null;
    tmpMatch = /20:(?<reg>[0-9a-fA-F]{16});/.exec(brkResponse);
    pc = tmpMatch ? tmpMatch.groups['reg'] : null;
    tmpMatch = /10:(?<reg>[0-9a-fA-F]{16});/.exec(brkResponse);
    x16 = tmpMatch ? tmpMatch.groups['reg'] : null;
    if (!tid || !pc || !x16) {
        log(`Failed to extract registers: tid=${tid}, pc=${pc}, x16=${x16}`);
        break;
    }
    pc = littleEndianHexStringToNumber(pc);
    x16 = littleEndianHexStringToNumber(x16);

    let instructionResponse = send_command(`m${pc.toString(16)},4`);
    if (!instructionResponse || instructionResponse.startsWith('E') || instructionResponse.length < 8) {
        log(`Failed to read instruction at 0x${pc.toString(16)}: ${instructionResponse}`);
        break;
    }
    let instrU32 = littleEndianHexToU32(instructionResponse);
    let brkImmediate = extractBrkImmediate(instrU32);
    if (legacyCommands[brkImmediate] !== undefined) {
        tmpMatch = /00:(?<reg>[0-9a-fA-F]{16});/.exec(brkResponse);
        x0 = tmpMatch ? tmpMatch.groups['reg'] : null;
        tmpMatch = /01:(?<reg>[0-9a-fA-F]{16});/.exec(brkResponse);
        x1 = tmpMatch ? tmpMatch.groups['reg'] : null;
        if (!x0 || !x1) {
            break;
        }
        x0 = littleEndianHexStringToNumber(x0);
        x1 = littleEndianHexStringToNumber(x1);

        let pcPlus4 = numberToLittleEndianHexString(pc + 4n);
        send_command(`P20=${pcPlus4};thread:${tid};`);

        const command = legacyCommands[brkImmediate];
        command();
    } else {
        log(`Unhandled brk immediate 0x${brkImmediate.toString(16)}; detaching`);
        break;
    }
}

function JIT26Detach() {
    send_command(`D`);
    detached = true;
}

function JIT26HandleBrk0x69() {
    // 64-bit little-endian hex for 0x00000000E0000069
    send_command(`P0=690000e000000000;thread:${tid};`);
}

function JIT26HandleBrk0xf00d() {
    const command = commands[Number(x16)];
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
        if (!requestRXResponse || requestRXResponse.startsWith('E') || !/^[0-9a-fA-F]{5,16}$/.test(requestRXResponse)) {
            log(`Failed to allocate RX memory: ${requestRXResponse}`);
            send_command(`P0=0000000000000000;thread:${tid};`);
            return;
        }
        jitPageAddress = BigInt(`0x${requestRXResponse}`);
    }
    prepare_memory_region(jitPageAddress, x1);
    send_command(`P0=${numberToLittleEndianHexString(jitPageAddress)};thread:${tid};`);
}

function littleEndianHexStringToNumber(hexStr) {
    const padded = hexStr.padEnd(16, '0');
    const bytes = [];
    for (let i = 0; i < 16; i += 2) {
        bytes.push(parseInt(padded.substr(i, 2), 16));
    }
    let num = 0n;
    for (let i = 7; i >= 0; i--) {
        num = (num << 8n) | BigInt(bytes[i]);
    }
    return num;
}

function numberToLittleEndianHexString(num) {
    const bytes = [];
    for (let i = 0; i < 8; i++) {
        bytes.push(Number(num & 0xFFn));
        num >>= 8n;
    }
    return bytes.map(b => b.toString(16).padStart(2, '0')).join('');
}

function littleEndianHexToU32(hexStr) {
    return parseInt(hexStr.substr(0, 8).match(/../g).reverse().join(''), 16);
}

function extractBrkImmediate(u32) {
    return (u32 >> 5) & 0xFFFF;
}

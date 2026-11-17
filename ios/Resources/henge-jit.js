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
let nextResumeCmd = 'c';
try {
    while (!detached && totalBreakpoints < 256) {
        totalBreakpoints++;
        log(`Handling breakpoint ${totalBreakpoints}`);

        const resumeCmd = nextResumeCmd;
        nextResumeCmd = 'c';
        let rawBrkResponse = send_command(resumeCmd);
        let brkResponse = expandRspRle(rawBrkResponse);
        log(`brkResponse = ${brkResponse}`);
        if (!brkResponse || brkResponse.startsWith('E') || brkResponse.startsWith('W') || brkResponse.startsWith('X')) {
            log(`Target exited or errored: ${brkResponse}`);
            break;
        }

        let stopSigMatch = /^T([0-9a-fA-F]{2})/.exec(brkResponse);
        let stopSig = stopSigMatch ? parseInt(stopSigMatch[1], 16) : 0;

        let tmpMatch = /T[0-9a-fA-F]+thread:(?<tid>[0-9a-fA-F]+);/.exec(brkResponse);
        tid = tmpMatch ? tmpMatch.groups['tid'] : null;
        if (!tid) {
            log(`Failed to extract thread id from stop packet: ${brkResponse}`);
            break;
        }

        // Forward non-SIGTRAP signals instead of dropping them or spinning on fatal faults.
        if (stopSig !== 0 && stopSig !== 5) {
            if (stopSig === 4 || stopSig === 6 || stopSig === 10 || stopSig === 11) {
                log(`Fatal signal 0x${stopSigMatch[1]} during JIT handshake; detaching`);
                break;
            }
            nextResumeCmd = `C${stopSigMatch[1]}`;
            continue;
        }

        pc = readReg(brkResponse, '20', tid);
        x16 = readReg(brkResponse, '10', tid);
        if (!pc || !x16) {
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
        if (!isArm64BrkInstruction(instrU32)) {
            log(`Non-BRK stop at 0x${pc.toString(16)} (insn=0x${instrU32.toString(16)}); continuing`);
            continue;
        }

        let brkImmediate = extractBrkImmediate(instrU32);
        if (legacyCommands[brkImmediate] !== undefined) {
            x0 = readReg(brkResponse, '00', tid);
            x1 = readReg(brkResponse, '01', tid);
            if (!x0 || !x1) {
                log(`Failed to read x0/x1 for brk #0x${brkImmediate.toString(16)}`);
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
} finally {
    if (!detached) {
        try {
            send_command(`D`);
        } catch (err) {
            log(`Detach cleanup error: ${err}`);
        }
        detached = true;
    }
}

function expandRspRle(packet) {
    if (!packet || packet.indexOf('*') === -1) {
        return packet;
    }
    let out = '';
    for (let i = 0; i < packet.length; i++) {
        if (i + 2 < packet.length && packet[i + 1] === '*') {
            const code = packet.charCodeAt(i + 2);
            if (code >= 32 && code <= 126) {
                out += packet[i].repeat(Math.max(1, code - 29));
                i += 2;
                continue;
            }
        }
        out += packet[i];
    }
    return out;
}

function readReg(stopPacket, regHex, threadId) {
    const rx = new RegExp(`(?:^|[;:])${regHex}:(?<reg>[0-9a-fA-F]{16});`);
    const match = rx.exec(stopPacket);
    if (match && match.groups && match.groups['reg']) {
        return match.groups['reg'];
    }
    const fallback = expandRspRle(send_command(`p${regHex};thread:${threadId};`));
    if (fallback && /^[0-9a-fA-F]{16}$/.test(fallback)) {
        return fallback;
    }
    return null;
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
    } else {
        log(`Unknown brk #0xf00d command x16=${x16}; returning 0`);
        send_command(`P0=0000000000000000;thread:${tid};`);
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
    const minTxmVA = 0x100000000n;
    const maxTxmVA = 0x1000000000n;
    if (jitPageAddress < minTxmVA || (jitPageAddress + x1) > maxTxmVA) {
        log(`Allocated RX region 0x${jitPageAddress.toString(16)} outside TXM [4 GiB, 64 GiB) bounds.`);
        send_command(`P0=0000000000000000;thread:${tid};`);
        return;
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
    return parseInt(hexStr.substr(0, 8).match(/../g).reverse().join(''), 16) >>> 0;
}

function isArm64BrkInstruction(u32) {
    return ((u32 & 0xFFE0001F) >>> 0) === 0xD4200000;
}

function extractBrkImmediate(u32) {
    return (u32 >>> 5) & 0xFFFF;
}

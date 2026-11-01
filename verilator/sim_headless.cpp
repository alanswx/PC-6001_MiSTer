// Headless PC-6001 simulation: run frames, type keys, capture PNG screenshots, frame hashes and traces.
//
// Organised as SMC777_MiSTer's verilator/sim_headless.cpp (same option names), cut down to what this core has.
// Examples:
//
//   ./obj_dir_headless/Vtop --rom-dir ../rom --stop-at-frame 300 --screenshot 300
//   ./obj_dir_headless/Vtop --rom-dir ../rom --stop-at-frame 200 --frame-log out/frames.csv --trace-io out/io.csv
//
// A frame ends when vertical blanking starts; frame 0 is the first full one after reset. Each PNG is the visible
// picture as the core outputs it, 320x240 (256x192 active with the border).

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <string>
#include <vector>
#include <set>
#include <map>
#include <deque>
#include <cstring>
#include <algorithm>
#include <sys/stat.h>

#include "Vtop.h"
#include "Vtop___024root.h"
#include "verilated.h"
#include "verilated_save.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#include "ps2_keys.h"

static const double CLK_HZ = 28636364.0;   // clk_sys, as the MiSTer

struct TypeCmd { uint32_t frame; std::string text; };

struct Options {
    uint32_t    stop_frame = 60;
    bool        quiet = false;
    std::set<uint32_t> screenshots;       // --screenshot N
    uint32_t    dump_every = 0;
    std::string out_dir = "out";
    std::string frame_log;
    std::vector<TypeCmd> types;
    std::vector<std::string> after_motor; // --after-motor TEXT: typed when the tape motor stops (one per stop)
    uint32_t    tape_end_stop = 0;        // --stop-after-motor N: end when the motor has stayed off N frames
    std::string dump_ram;                 // --dump-ram FILE: the 32 KB RAM at 8000h at the end (the mkII: all 64 KB)
    uint32_t    nudge = 0;                // --nudge N: idle N frames with tape left: press Space, then Return (4 times)
    uint32_t    type_press = 4, type_release = 4;
    std::string trace_file;               // --trace-cpu
    std::string io_file;                  // --trace-io
    uint32_t    trace_from = 0, trace_to = 0xFFFFFFFF;
    std::string basic_rom, cg_rom;        // --rom-dir DIR: DIR/BASICROM.60, DIR/CGROM60.60
    bool        ram16k = false;
    std::string tape_file;                // --tape FILE: .p6/.cas image through ioctl index 1
    std::string cart_file;                // --cart FILE: cartridge ROM through ioctl index 2
    std::string disk_rom;                 // DIR/DISK.ROM from --rom-dir: the PC-6031's firmware, at 5000h of boot.rom
    std::string rom_dir = "../rom";       // boot1.rom (the mkII's ROMs) is made from DIR/*.62
    bool mk2 = false;                     // --mk2: OSD Model = PC-6001mkII
    std::string disk_file;                // --disk FILE: a .d88 mounted as S0
    std::string disk_out;                 // --disk-out FILE: the image as the drive left it, written at the end
    int         composite = -1;               // --composite N: OSD Video = Composite, B/W graphics on TV = N
    bool        kbd_us = false;               // --kbd-us: OSD Keyboard = US (symbols); --type then types US keys
    bool        tape_turbo = false;           // --tape-turbo: OSD Tape speed 7x (the OSD default; here Normal)
    bool        tape_overlay = true;          // --no-tape-overlay: OSD Tape overlay Off
    struct JoyEv { uint32_t frame; int port; uint32_t bits; };
struct TouchEv { uint32_t frame; int x, y, pen; };
    std::vector<JoyEv> joy;               // --joy FRAME:PORT:BITS
    std::vector<TouchEv> touch;           // --touch FRAME:X,Y,PEN (puts the touch panel on joystick 2)
    std::vector<TouchEv> mouse;           // --mouse FRAME:DX,DY,BTN: one PS/2 report into rtl/touch_mouse.sv
    std::set<uint32_t> resets;            // --reset-at FRAME
    std::string wav_file;                 // --wav
    uint32_t    save_frame = 0;           // --save-state FRAME:FILE
    std::string save_file;
    std::string load_file;                // --load-state FILE
};

static void usage()
{
    fprintf(stderr,
"usage: Vtop [options]\n"
"  --stop-at-frame N      exit after frame N (default 60)\n"
"  --quiet                no progress on stderr\n"
"  --rom-dir DIR          DIR/BASICROM.60 and DIR/CGROM60.60 (default ../rom); --basic FILE / --cgrom FILE\n"
"  --mk2                  OSD Model = PC-6001mkII (boot1.rom from DIR/*.62)\n"
"  --ram16k               16 KB RAM (C000-FFFF) instead of 32 KB\n"
"  --cart FILE            load a cartridge ROM (OSD Cartridge); BASIC boots it\n"
"  --composite N          the picture as a TV decodes it (rtl/pc6001_composite.sv); N, the black/white\n"
"                         graphics mode on that TV: 0 red/blue, 1 blue/red, 2 pink/green, 3 green/pink, 4 grey\n"
"  --kbd-us               OSD Keyboard = US: symbols as on a US keyboard (--type uses US keys)\n"
"  --disk FILE            mount a .d88 (OSD Disk); the PC-6031 unit is there when DIR/DISK.ROM is (--no-disk-unit:\n"
"                         leave it out); --disk-out FILE writes the image as the drive left it\n"
"  --tape FILE            load a .p6/.cas tape image (OSD Load Tape); --tape-turbo: OSD Tape speed 7x\n"
"  --no-tape-overlay      OSD Tape overlay Off (no status bar while the tape plays)\n"
"  --after-motor TEXT     type TEXT 20 frames after the tape motor stops (repeatable: one per stop, in order)\n"
"  --stop-after-motor N   stop once the motor has stopped (after every --after-motor text) and stayed off\n"
"                         N frames; writes last.png and prints a TAPE line\n"
"  --dump-ram FILE        write the RAM (8000-FFFF, 32 KB; --mk2 0000-FFFF) to FILE at the end\n"
"  --nudge N              with --stop-after-motor: when the machine waits N frames with tape left, press\n"
"                         Space, then Return (up to 4 presses), as a user reading a title screen would\n"
"  --type FRAME:TEXT      type TEXT from FRAME; \\n or {RETURN}, {STOP}, {F1}, {WAITn} ...\n"
"  --type-rate P:R        frames per key press:release (default 4:4)\n"
"  --touch F:X,Y,PEN      touch panel on joystick 2: from frame F, X 0-255, Y 0-255, PEN 1 = down\n"
"  --mouse F:DX,DY,BTN    touch panel worked by the mouse (rtl/touch_mouse.sv): a report at frame F, DY down\n"
"  --joy F:PORT:BITS      joystick PORT (0/1) from frame F: MiSTer bits (1 right 2 left 4 down 8 up 16/32 buttons)\n"
"  --reset-at F           reset before frame F\n"
"  --screenshot N         PNG of frame N (repeatable); --dump-every K: every Kth frame\n"
"  --out DIR              output directory (default ./out)\n"
"  --frame-log FILE       frame,fb_hash,cpu_cycles,pc per frame\n"
"  --trace-cpu FILE       frame,cpu_cycle,pc at each instruction fetch (M1)\n"
"  --trace-io FILE        frame,cpu_cycle,pc,kind,address,data for each IN/OUT\n"
"  --trace-from N         start tracing at frame N; --trace-to N stops after frame N\n"
"  --wav FILE             record the audio output (48 kHz, 16-bit stereo WAV)\n"
"  --save-state N:FILE    save the machine state at the start of frame N; --load-state FILE resumes from it\n"
"fb_hash is FNV-1a 32 over the RGB888 bytes of the visible picture (320x240).\n");
}

static void mkdir_p(const std::string &path)
{
    for (size_t i = 1; i <= path.size(); i++)
        if (i == path.size() || path[i] == '/') mkdir(path.substr(0, i).c_str(), 0777);
}

static uint32_t parse_num(const std::string &s) { return (uint32_t)std::stoul(s, nullptr, 0); }

static bool parse_args(int argc, char **argv, Options &o)
{
    o.basic_rom = "../rom/BASICROM.60";
    o.cg_rom = "../rom/CGROM60.60";
    o.disk_rom = "../rom/DISK.ROM";
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&]() -> std::string {
            if (i + 1 >= argc) { fprintf(stderr, "%s needs an argument\n", a.c_str()); exit(2); }
            return argv[++i];
        };
        auto pair = [&](const char *what, uint32_t &x, std::string &y) -> bool {
            std::string s = next();
            size_t c = s.find(':');
            if (c == std::string::npos) { fprintf(stderr, "%s wants %s\n", a.c_str(), what); return false; }
            x = parse_num(s.substr(0, c)); y = s.substr(c + 1);
            return true;
        };
        std::string rest;
        if (a == "--help" || a == "-h") { usage(); exit(0); }
        else if (a == "--headless") {}
        else if (a == "--stop-at-frame") o.stop_frame = parse_num(next());
        else if (a == "--quiet") o.quiet = true;
        else if (a == "--after-motor") o.after_motor.push_back(next());
        else if (a == "--dump-ram") o.dump_ram = next();
        else if (a == "--nudge") o.nudge = parse_num(next());
        else if (a == "--stop-after-motor") o.tape_end_stop = parse_num(next());
        else if (a == "--type") { uint32_t f; if (!pair("FRAME:TEXT", f, rest)) return false; o.types.push_back({f, rest}); }
        else if (a == "--type-rate") { if (!pair("P:R", o.type_press, rest)) return false; o.type_release = parse_num(rest); }
        else if (a == "--screenshot") o.screenshots.insert(parse_num(next()));
        else if (a == "--dump-every") o.dump_every = parse_num(next());
        else if (a == "--out") o.out_dir = next();
        else if (a == "--frame-log") o.frame_log = next();
        else if (a == "--trace-cpu") o.trace_file = next();
        else if (a == "--trace-io") o.io_file = next();
        else if (a == "--trace-from") o.trace_from = parse_num(next());
        else if (a == "--trace-to") o.trace_to = parse_num(next());
        else if (a == "--rom-dir") { std::string d = next(); o.rom_dir = d; o.basic_rom = d + "/BASICROM.60"; o.cg_rom = d + "/CGROM60.60"; o.disk_rom = d + "/DISK.ROM"; }
        else if (a == "--mk2") o.mk2 = true;
        else if (a == "--no-disk-unit") o.disk_rom.clear();
        else if (a == "--disk") o.disk_file = next();
        else if (a == "--disk-out") o.disk_out = next();
        else if (a == "--basic") o.basic_rom = next();
        else if (a == "--cgrom") o.cg_rom = next();
        else if (a == "--ram16k") o.ram16k = true;
        else if (a == "--tape") o.tape_file = next();
        else if (a == "--cart") o.cart_file = next();
        else if (a == "--tape-turbo" || a == "--tape-fast") o.tape_turbo = true;
        else if (a == "--kbd-us") o.kbd_us = true;
        else if (a == "--composite") o.composite = parse_num(next()) % 5;
        else if (a == "--no-tape-overlay") o.tape_overlay = false;
        else if (a == "--reset-at") o.resets.insert(parse_num(next()));
        else if (a == "--touch") {
            Options::TouchEv t;
            if (sscanf(next().c_str(), "%u:%d,%d,%d", &t.frame, &t.x, &t.y, &t.pen) != 4) { fprintf(stderr, "--touch wants F:X,Y,PEN\n"); return false; }
            o.touch.push_back(t);
        }
        else if (a == "--mouse") {
            Options::TouchEv t;
            if (sscanf(next().c_str(), "%u:%d,%d,%d", &t.frame, &t.x, &t.y, &t.pen) != 4) { fprintf(stderr, "--mouse wants F:DX,DY,BTN\n"); return false; }
            o.mouse.push_back(t);
        }
        else if (a == "--joy") {
            Options::JoyEv j{};
            if (sscanf(next().c_str(), "%u:%d:%i", &j.frame, &j.port, &j.bits) != 3) { fprintf(stderr, "--joy wants F:PORT:BITS\n"); return false; }
            o.joy.push_back(j);
        }
        else if (a == "--wav") o.wav_file = next();
        else if (a == "--save-state") { if (!pair("FRAME:FILE", o.save_frame, o.save_file)) return false; }
        else if (a == "--load-state") o.load_file = next();
        else if (a[0] == '+') {}   // Verilator plusargs
        else { fprintf(stderr, "unknown option %s (try --help)\n", a.c_str()); return false; }
    }
    return true;
}

struct Ps2Event { uint8_t code; bool ext; bool press; };

class Sim {
public:
    explicit Sim(const Options &o) : opt(o) { top = new Vtop; }
    ~Sim() { top->final(); delete top; }
    int run();
private:
    const Options &opt;
    Vtop     *top;
    uint64_t  cycle = 0, cpu_cycles = 0;
    uint32_t  frame = 0;
    int       exit_code = 0;
    bool      done = false;
    std::vector<uint8_t> last_fb;           // the last complete frame
    int       last_h = 0;
    bool      started = false;            // frames are counted from the first full one after reset
    std::vector<uint8_t> fb, line;
    int       fb_w = 0, fb_h = 0;
    bool      prev_hb = false, prev_vb = false;
    FILE     *flog = nullptr, *ftrace = nullptr, *fio = nullptr;
    bool      prev_m1 = true;
    bool      prev_motor = false;
    size_t    motor_stops = 0;
    uint32_t  tape_end_frame = 0;         // first frame with every tape byte played (0: not yet)
    uint32_t  motor_on_frames = 0;
    uint32_t  motor_off_frame = 0;        // frame of the last motor stop
    uint32_t  nudge_frame = 0, nudges = 0;
    uint16_t  last_pc = 0;
    std::multimap<uint32_t, Ps2Event> ps2_schedule;
    std::deque<Ps2Event> ps2_queue;
    uint64_t  ps2_next_ok = 0;
    bool      ps2_toggle = false;
    FILE     *fwav = nullptr;
    uint32_t  wav_samples = 0;
    double    wav_next = 0;
    struct HState {
        uint64_t cycle, cpu_cycles, ps2_next_ok;
        uint32_t frame;
        uint8_t  prev_hb, prev_vb, prev_m1, ps2_toggle;
        uint16_t last_pc;
        int32_t  fb_w;
    };
    // the disk image (hps_io S0): blocks of 512 bytes, one byte every 2 clocks
    std::vector<uint8_t> disk;
    int       sd_state = 0;               // 0 idle, 1 read block, 2 write block
    uint32_t  sd_blk = 0, sd_i = 0, sd_wait = 0;
    bool      disk_written = false;
    void sd_service();
    void disk_mount();
    void clock();
    void end_frame();
    bool tracing() const { return started && frame >= opt.trace_from && frame <= opt.trace_to; }
    bool want_png(uint32_t f) const;
    void write_png(uint32_t f);
    void schedule_typing();
    void schedule_text(uint32_t f, const std::string &s);
    bool load_rom();
    void ioctl_load(uint32_t base, const std::vector<uint8_t> &data, int index = 0);
    void save_state();
    bool load_state();
    void wav_close();
    void reset_machine();
};

void Sim::reset_machine()
{
    top->reset = 1;
    for (int i = 0; i < 64; i++) clock();
    top->reset = 0;
    if (!opt.quiet) fprintf(stderr, "[sim] reset before frame %u\n", frame);
}

static bool read_file(const std::string &name, std::vector<uint8_t> &out)
{
    FILE *f = fopen(name.c_str(), "rb");
    if (!f) return false;
    uint8_t buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) out.insert(out.end(), buf, buf + n);
    fclose(f);
    return true;
}

// hps_io style download: one byte every 4 clocks, machine held in reset by ioctl_download.
void Sim::ioctl_load(uint32_t base, const std::vector<uint8_t> &data, int index)
{
    top->ioctl_index = index;
    top->ioctl_download = 1;
    for (size_t i = 0; i < data.size(); i++) {
        top->ioctl_addr = base + (uint32_t)i;
        top->ioctl_dout = data[i];
        top->ioctl_wr = 1;
        clock();
        top->ioctl_wr = 0;
        clock(); clock(); clock();
        while (top->ioctl_wait) clock();
    }
    top->ioctl_download = 0;
}

// Main mounting the image: img_mounted for one clock with its size
void Sim::disk_mount()
{
    top->img_size = disk.size();
    top->img_readonly = 0;
    top->img_mounted = 1;
    clock();
    top->img_mounted = 0;
}

// hps_io's side of sd_rd / sd_wr: sd_ack for the block, sd_buff_wr per byte read in, sd_buff_din sampled per byte
// written out (the core's RAM has one clock of latency, so each address is held for 2 clocks)
void Sim::sd_service()
{
    if (sd_state == 0) {
        if (top->sd_rd || top->sd_wr) {
            sd_state = top->sd_rd ? 1 : 2;
            sd_blk = top->sd_lba;
            sd_i = 0; sd_wait = 0;
            top->sd_ack = 1;
            top->sd_buff_addr = 0;
            top->sd_buff_wr = 0;
        }
        return;
    }
    if (sd_state == 1) {
        if (top->sd_buff_wr) { top->sd_buff_wr = 0; if (++sd_i == 512) { top->sd_ack = 0; sd_state = 0; } return; }
        uint32_t a = sd_blk * 512 + sd_i;
        top->sd_buff_addr = sd_i;
        top->sd_buff_dout = a < disk.size() ? disk[a] : 0;
        top->sd_buff_wr = 1;
        return;
    }
    // write: the address was set last time; the data is there after two clocks
    if (++sd_wait < 3) return;
    sd_wait = 0;
    uint32_t a = sd_blk * 512 + sd_i;
    if (a < disk.size()) { disk[a] = top->sd_buff_din; disk_written = true; }
    if (++sd_i == 512) { top->sd_ack = 0; sd_state = 0; return; }
    top->sd_buff_addr = sd_i;
}

// boot.rom as the MiSTer loads it: BASICROM.60 (16 KB) at 0, CGROM60.60 (4 KB) at 4000h
bool Sim::load_rom()
{
    std::vector<uint8_t> d, cg;
    if (!read_file(opt.basic_rom, d)) { fprintf(stderr, "cannot read BASIC ROM %s\n", opt.basic_rom.c_str()); return false; }
    if (d.size() != 0x4000) fprintf(stderr, "warning: %s is %zu bytes, expected 16384\n", opt.basic_rom.c_str(), d.size());
    d.resize(0x4000, 0xFF);
    if (!read_file(opt.cg_rom, cg)) { fprintf(stderr, "cannot read CGROM %s\n", opt.cg_rom.c_str()); return false; }
    cg.resize(0x1000, 0xFF);
    d.insert(d.end(), cg.begin(), cg.end());
    // DISK.ROM at 5000h (2 KB): the PC-6031 disk unit
    std::vector<uint8_t> dr;
    if (!opt.disk_rom.empty() && read_file(opt.disk_rom, dr)) {
        dr.resize(0x800, 0xFF);
        d.insert(d.end(), dr.begin(), dr.end());
        if (!opt.quiet) fprintf(stderr, "[sim] boot.rom: + '%s' (disk unit)\n", opt.disk_rom.c_str());
    }
    ioctl_load(0, d);
    if (!opt.quiet) fprintf(stderr, "[sim] boot.rom: '%s' + '%s'\n", opt.basic_rom.c_str(), opt.cg_rom.c_str());

    // boot1.rom, as Main loads it at the core's start (ioctl_index 40h), only with --mk2 so that the PC-6001's
    // runs keep their timing: the mkII's ROMs in MAME's order,
    // BASICROM.62 (32 KB), VOICEROM.62 (16 KB) at 8000h, CGROM60.62 at C000h, CGROM60m.62 at E000h (8 KB each),
    // KANJIROM.62 (32 KB) at 10000h
    static const struct { const char *name; uint32_t at, size; } mk2[] = {
        { "BASICROM.62", 0x00000, 0x8000 }, { "VOICEROM.62", 0x08000, 0x4000 }, { "CGROM60.62", 0x0c000, 0x2000 },
        { "CGROM60m.62", 0x0e000, 0x2000 }, { "KANJIROM.62", 0x10000, 0x8000 } };
    if (!opt.mk2) return true;
    std::vector<uint8_t> b1(0x18000, 0xFF);
    bool any = false;
    for (auto &m : mk2) {
        std::vector<uint8_t> f;
        if (!read_file(opt.rom_dir + "/" + m.name, f)) {
            fprintf(stderr, "warning: %s/%s not found (boot1.rom)\n", opt.rom_dir.c_str(), m.name);
            continue;
        }
        f.resize(m.size, 0xFF);
        std::copy(f.begin(), f.end(), b1.begin() + m.at);
        any = true;
    }
    if (any) {
        ioctl_load(0, b1, 0x40);
        if (!opt.quiet) fprintf(stderr, "[sim] boot1.rom: the mkII's ROMs from '%s'\n", opt.rom_dir.c_str());
    }
    return true;
}

static void wav_header(FILE *f, uint32_t samples)
{
    uint32_t data = samples * 4, riff = 36 + data, fmt_len = 16, rate = 48000, brate = 48000 * 4;
    uint16_t pcm = 1, ch = 2, align = 4, bits = 16;
    fseek(f, 0, SEEK_SET);
    fwrite("RIFF", 1, 4, f); fwrite(&riff, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f);
    fwrite(&fmt_len, 4, 1, f); fwrite(&pcm, 2, 1, f); fwrite(&ch, 2, 1, f); fwrite(&rate, 4, 1, f);
    fwrite(&brate, 4, 1, f); fwrite(&align, 2, 1, f); fwrite(&bits, 2, 1, f);
    fwrite("data", 1, 4, f); fwrite(&data, 4, 1, f);
}

void Sim::wav_close()
{
    if (!fwav) return;
    wav_header(fwav, wav_samples);
    fclose(fwav);
    fwav = nullptr;
}

void Sim::save_state()
{
    VerilatedSave os;
    os.open(opt.save_file.c_str());
    os << *top;
    HState h = {cycle, cpu_cycles, ps2_next_ok, frame, prev_hb, prev_vb, prev_m1, ps2_toggle, last_pc, fb_w};
    os.write(&h, sizeof(h));
    os.close();
    if (!opt.quiet) fprintf(stderr, "[sim] state saved at frame %u to %s\n", frame, opt.save_file.c_str());
}

bool Sim::load_state()
{
    VerilatedRestore is;
    is.open(opt.load_file.c_str());
    if (!is.isOpen()) { fprintf(stderr, "cannot read %s\n", opt.load_file.c_str()); return false; }
    is >> *top;
    HState h;
    is.read(&h, sizeof(h));
    is.close();
    cycle = h.cycle; cpu_cycles = h.cpu_cycles; ps2_next_ok = h.ps2_next_ok; frame = h.frame;
    prev_hb = h.prev_hb; prev_vb = h.prev_vb; prev_m1 = h.prev_m1; ps2_toggle = h.ps2_toggle;
    last_pc = h.last_pc; fb_w = h.fb_w;
    if (!opt.quiet) fprintf(stderr, "[sim] state loaded from %s, frame %u\n", opt.load_file.c_str(), frame);
    return true;
}

void Sim::clock()
{
    // Sample what the video pipeline sees at this rising edge: MiSTer's video_mixer latches RGB on the
    // clk_sys edge where CE_PIXEL is high.
    top->clk_sys = 0;
    top->eval();
    if (top->ce_pix) {
        bool hb = top->VGA_HB, vb = top->VGA_VB;
        if (!hb && !vb) {
            line.push_back(top->VGA_R);
            line.push_back(top->VGA_G);
            line.push_back(top->VGA_B);
        }
        if (hb && !prev_hb && !line.empty()) {
            int w = (int)line.size() / 3;
            if (fb_h == 0) fb_w = w;
            line.resize((size_t)fb_w * 3, 0);
            fb.insert(fb.end(), line.begin(), line.end());
            fb_h++;
            line.clear();
        }
        prev_hb = hb;
        if (vb && !prev_vb) end_frame();
        prev_vb = vb;
    }
    top->clk_sys = 1;
    top->eval();
    cycle++;
    sd_service();
    if (top->cpu_ce) cpu_cycles++;

    if (fwav && cycle >= wav_next) {
        int16_t lr[2] = {(int16_t)top->AUDIO_L, (int16_t)top->AUDIO_R};
        fwrite(lr, 2, 2, fwav);
        wav_samples++;
        wav_next += CLK_HZ / 48000.0;
    }

    if (top->tape_motor != prev_motor) {
        prev_motor = top->tape_motor;
        if (!opt.quiet) fprintf(stderr, "[sim] frame %u: tape motor %s\n", frame, prev_motor ? "on" : "off");
        if (!prev_motor && started) {
            if (motor_stops < opt.after_motor.size()) schedule_text(frame + 20, opt.after_motor[motor_stops]);
            motor_stops++;
            motor_off_frame = frame;
        }
    }

    bool m1 = top->cpu_m1_n;
    if (!m1 && prev_m1) {
        last_pc = top->cpu_addr;
        if (ftrace && tracing()) fprintf(ftrace, "%u,%llu,%04x\n", frame, (unsigned long long)cpu_cycles, last_pc);
    }
    prev_m1 = m1;
    if (fio && tracing() && (top->dbg_io_wr || top->dbg_io_rd))
        fprintf(fio, "%u,%llu,%04x,%c,%02x,%02x\n", frame, (unsigned long long)cpu_cycles, last_pc,
                top->dbg_io_wr ? 'W' : 'R', top->dbg_io_port, top->dbg_io_data);

    // hps_io style ps2_key: bit 10 toggles per event, 9 = pressed, 8 = extended. One event per ~1 ms.
    if (!ps2_queue.empty() && cycle >= ps2_next_ok) {
        Ps2Event e = ps2_queue.front();
        ps2_queue.pop_front();
        ps2_toggle = !ps2_toggle;
        top->ps2_key = (uint16_t)((ps2_toggle << 10) | (e.press << 9) | (e.ext << 8) | e.code);
        ps2_next_ok = cycle + (uint64_t)(CLK_HZ / 1000);
    }
}

void Sim::end_frame()
{
    if (!started) { fb.clear(); fb_h = 0; line.clear(); started = true; return; }
    uint32_t h = 2166136261u;
    for (uint8_t b : fb) { h ^= b; h *= 16777619u; }
    if (flog) fprintf(flog, "%u,%08x,%llu,%04x\n", frame, h, (unsigned long long)cpu_cycles, last_pc);
    if (want_png(frame)) write_png(frame);
    if (opt.tape_end_stop) { last_fb = fb; last_h = fb_h; }
    if (!opt.quiet && frame % 50 == 0)
        fprintf(stderr, "[sim] frame %u  %.3fs emulated  %dx%d  pc %04x  hash %08x\n",
                frame, cycle / CLK_HZ, fb_w, fb_h, last_pc, h);
    fb.clear(); fb_h = 0; line.clear();
    if (top->tape_motor) motor_on_frames++;
    if (!tape_end_frame && top->tape_length && top->tape_position >= top->tape_length) tape_end_frame = frame;
    if (opt.tape_end_stop && motor_stops && motor_stops >= opt.after_motor.size() && !top->tape_motor) {
        uint32_t idle = frame - std::max(motor_off_frame, nudge_frame);
        bool tape_left = top->tape_position + 16 < top->tape_length;
        if (opt.nudge && tape_left && nudges < 4 && idle >= opt.nudge) {
            schedule_text(frame + 1, nudges % 2 ? "\\n" : " ");
            nudges++;
            nudge_frame = frame;
        }
        else if (idle >= opt.tape_end_stop && (!opt.nudge || !tape_left || nudges >= 4)) done = true;
    }
    frame++;
    if (!opt.save_file.empty() && frame == opt.save_frame) save_state();
    auto range = ps2_schedule.equal_range(frame);
    for (auto it = range.first; it != range.second; ++it) ps2_queue.push_back(it->second);
    for (auto &j : opt.joy) if (j.frame == frame) { if (j.port) top->joy1 = j.bits; else top->joy0 = j.bits; }
    for (auto &t : opt.touch) if (t.frame == frame) { top->touch_x = t.x; top->touch_y = t.y; top->touch_pen = t.pen; }
    for (auto &m : opt.mouse) if (m.frame == frame) {
        // PS/2: b4/b5 the x/y signs, y counts up
        int dx = m.x, dy = -m.y;
        uint32_t r = (m.pen & 1) | (dx < 0 ? 0x10 : 0) | (dy < 0 ? 0x20 : 0) | ((dx & 0xff) << 8) | ((dy & 0xff) << 16);
        top->ps2_mouse = r | ((~top->ps2_mouse) & 0x1000000);
    }
    if (opt.resets.count(frame)) reset_machine();
}

bool Sim::want_png(uint32_t f) const
{
    if (opt.screenshots.count(f)) return true;
    if (opt.dump_every && f % opt.dump_every == 0) return true;
    return false;
}

void Sim::write_png(uint32_t f)
{
    if (fb_w == 0 || fb_h == 0) { fprintf(stderr, "[sim] frame %u: no picture\n", f); return; }
    char name[1024];
    snprintf(name, sizeof(name), "%s/frame_%06u.png", opt.out_dir.c_str(), f);
    if (!stbi_write_png(name, fb_w, fb_h, 3, fb.data(), fb_w * 3)) {
        fprintf(stderr, "cannot write %s\n", name);
        exit_code = 3;
    }
    else if (!opt.quiet) fprintf(stderr, "[sim] wrote %s (%dx%d)\n", name, fb_w, fb_h);
}

void Sim::schedule_typing()
{
    for (auto &t : opt.types) schedule_text(t.frame, t.text);
}

void Sim::schedule_text(uint32_t f, const std::string &s)
{
    {
        for (size_t i = 0; i < s.size(); i++) {
            Ps2Key k;
            bool ok = false;
            if (s[i] == '\\' && i + 1 < s.size()) {
                char c = s[++i];
                c = c == 'n' || c == 'r' ? '\n' : c;
                ok = opt.kbd_us ? ps2_from_ascii_us(c, k) : ps2_from_ascii(c, k);
            } else if (s[i] == '{') {
                size_t e = s.find('}', i);
                std::string name = s.substr(i + 1, e - i - 1);
                i = e;
                if (name.rfind("WAIT", 0) == 0) { f += parse_num(name.substr(4)); continue; }
                ok = ps2_from_name(name, k);
                if (!ok) fprintf(stderr, "--type: unknown key {%s}\n", name.c_str());
            } else {
                ok = opt.kbd_us ? ps2_from_ascii_us(s[i], k) : ps2_from_ascii(s[i], k);
                if (!ok) fprintf(stderr, "--type: no key for '%c'\n", s[i]);
            }
            if (!ok) continue;
            if (k.shift) ps2_schedule.insert({f, {PS2_LSHIFT, false, true}});
            ps2_schedule.insert({f, {k.code, k.extended, true}});
            ps2_schedule.insert({f + opt.type_press, {k.code, k.extended, false}});
            if (k.shift) ps2_schedule.insert({f + opt.type_press, {PS2_LSHIFT, false, false}});
            f += opt.type_press + opt.type_release;
        }
    }
}

int Sim::run()
{
    mkdir_p(opt.out_dir);
    if (!opt.frame_log.empty() && !(flog = fopen(opt.frame_log.c_str(), "w"))) { perror(opt.frame_log.c_str()); return 2; }
    if (!opt.trace_file.empty() && !(ftrace = fopen(opt.trace_file.c_str(), "w"))) { perror(opt.trace_file.c_str()); return 2; }
    if (!opt.io_file.empty() && !(fio = fopen(opt.io_file.c_str(), "w"))) { perror(opt.io_file.c_str()); return 2; }
    if (flog) fprintf(flog, "frame,fb_hash,cpu_cycles,pc\n");
    if (ftrace) fprintf(ftrace, "frame,cpu_cycle,pc\n");
    if (fio) fprintf(fio, "frame,cpu_cycle,pc,kind,address,data\n");
    if (!opt.wav_file.empty()) {
        if (!(fwav = fopen(opt.wav_file.c_str(), "wb"))) { perror(opt.wav_file.c_str()); return 2; }
        wav_header(fwav, 0);
    }

    top->ram16k = opt.ram16k;
    top->mk2 = opt.mk2;
    top->tape_turbo = opt.tape_turbo;
    top->kbd_us = opt.kbd_us;
    top->composite = opt.composite >= 0;
    top->comp_bw = opt.composite > 0 ? opt.composite : 0;
    top->tape_overlay = opt.tape_overlay;
    top->tape_rewind = 0;
    top->reset = 1;
    top->ps2_key = 0;
    top->joy0 = top->joy1 = 0;
    top->touch_en = !opt.touch.empty() || !opt.mouse.empty();
    top->touch_mouse_on = !opt.mouse.empty();
    top->ps2_mouse = 0;
    top->touch_x = top->touch_y = 0; top->touch_pen = 0;
    for (int i = 0; i < 16; i++) clock();
    if (!opt.load_file.empty()) {
        if (!load_state()) return 2;
        top->ram16k = opt.ram16k;            // options are not part of the saved machine
        top->mk2 = opt.mk2;
        top->tape_turbo = opt.tape_turbo;
        top->tape_overlay = opt.tape_overlay;
    } else {
        if (!load_rom()) return 2;
        if (!opt.cart_file.empty()) {
            std::vector<uint8_t> c;
            if (!read_file(opt.cart_file, c)) { fprintf(stderr, "cannot read cartridge %s\n", opt.cart_file.c_str()); return 2; }
            ioctl_load(0, c, 0x02);
            if (!opt.quiet) fprintf(stderr, "[sim] cartridge: '%s', %zu bytes\n", opt.cart_file.c_str(), c.size());
        }
        if (!opt.disk_file.empty()) {
            if (!read_file(opt.disk_file, disk)) { fprintf(stderr, "cannot read disk %s\n", opt.disk_file.c_str()); return 2; }
            disk_mount();
            if (!opt.quiet) fprintf(stderr, "[sim] disk: '%s', %zu bytes\n", opt.disk_file.c_str(), disk.size());
        }
        for (int i = 0; i < 16; i++) clock();
        top->reset = 0;
    }
    if (!opt.tape_file.empty()) {
        std::vector<uint8_t> t;
        if (!read_file(opt.tape_file, t)) { fprintf(stderr, "cannot read tape %s\n", opt.tape_file.c_str()); return 2; }
        // Main puts the extension's place in the F1 list ("P6 CASP6T") in index bits 7:6
        std::string ext = opt.tape_file.substr(opt.tape_file.find_last_of('.') + 1);
        for (auto &c : ext) c = (char)tolower((unsigned char)c);
        ioctl_load(0, t, ext == "cas" ? 0x41 : ext == "p6t" ? 0x81 : 0x01);
        if (!opt.quiet) fprintf(stderr, "[sim] tape: '%s', %zu bytes\n", opt.tape_file.c_str(), t.size());
    }
    schedule_typing();
    auto range = ps2_schedule.equal_range(frame);
    for (auto it = range.first; it != range.second; ++it) ps2_queue.push_back(it->second);

    while (frame <= opt.stop_frame && !done && !Verilated::gotFinish()) clock();
    if (!opt.dump_ram.empty()) {
        FILE *fr = fopen(opt.dump_ram.c_str(), "wb");
        if (!fr) perror(opt.dump_ram.c_str());
        else {
            // the PC-6001's 32 KB at 8000h; the mkII's whole 64 KB
            for (int i = opt.mk2 ? 0 : 0x8000; i < 0x10000; i++) { uint8_t v = top->rootp->top__DOT__pc6001__DOT__ram[i]; fwrite(&v, 1, 1, fr); }
            fclose(fr);
        }
    }
    if (opt.tape_end_stop) {
        // the last frame, for a sweep: a screenshot and one summary line
        char name[1024];
        snprintf(name, sizeof(name), "%s/last.png", opt.out_dir.c_str());
        if (fb_w && last_h) stbi_write_png(name, fb_w, last_h, 3, last_fb.data(), fb_w * 3);
        printf("TAPE end_frame=%u frames=%u motor_on_frames=%u motor_stops=%zu nudges=%u pos=%u len=%u\n",
               tape_end_frame, frame, motor_on_frames, motor_stops, nudges, (unsigned)top->tape_position, (unsigned)top->tape_length);
    }

    if (!opt.disk_out.empty() && !disk.empty()) {
        FILE *fd = fopen(opt.disk_out.c_str(), "wb");
        if (!fd) perror(opt.disk_out.c_str());
        else { fwrite(disk.data(), 1, disk.size(), fd); fclose(fd); }
        if (!opt.quiet) fprintf(stderr, "[sim] disk written to '%s'%s\n", opt.disk_out.c_str(), disk_written ? "" : " (unchanged)");
    }
    wav_close();
    if (flog) fclose(flog);
    if (ftrace) fclose(ftrace);
    if (fio) fclose(fio);
    if (!opt.quiet) fprintf(stderr, "[sim] done: %u frames, %.3f s emulated\n", frame, cycle / CLK_HZ);
    return exit_code;
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    Options o;
    if (!parse_args(argc, argv, o)) return 2;
    Sim sim(o);
    return sim.run();
}

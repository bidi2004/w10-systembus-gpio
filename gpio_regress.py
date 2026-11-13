"""Full E203, physical SPI source, original System Bus, real shared SRAM.
Behavioral RTL validation; not a PPA result. No testbench task-data DUT writes.
"""
import argparse,hashlib,json,re,struct,subprocess,sys,shutil
from pathlib import Path
from datetime import datetime,timezone
P=Path(__file__).resolve().parents[1]
TOOLS=P.parent/'shuziic/shuziic/tools'
sys.path.insert(0,str(P/'sim/support'))
from soc_testbench import prepare_testbench

def modify():
 rtl=P/'vendor/e203_hbirdv2/rtl/e203'
 marker=P/'sysbus_source_changes.json'
 if marker.exists(): return
 changes=[]
 def edit(path,old,new):
  s=path.read_text(encoding='utf-8'); assert s.count(old)==1,(str(path),old,s.count(old))
  before=hashlib.sha256(path.read_bytes()).hexdigest()
  path.write_text(s.replace(old,new),encoding='utf-8')
  changes.append(dict(path=str(path.relative_to(P)),before=before,after=hashlib.sha256(path.read_bytes()).hexdigest()))
 # Export the platform's original bus clock and synchronized bus reset.
 main=rtl/'subsys/e203_subsys_main.v'; top=rtl/'subsys/e203_subsys_top.v';soc=rtl/'soc/e203_soc_top.v'
 edit(main,'module e203_subsys_main(','module e203_subsys_main(\n output kwt_bus_rst_n,')
 edit(main,'wire bus_rst_n  = main_rst_n;','wire bus_rst_n  = main_rst_n;\n assign kwt_bus_rst_n = bus_rst_n;')
 edit(top,'module e203_subsys_top(','module e203_subsys_top(\n output kwt_sys_clk, kwt_sys_rst_n,')
 edit(top,'wire hfclk;','wire hfclk;\n assign kwt_sys_clk = hfclk;')
 # Instance declaration may have whitespace; keep all bus routing untouched.
 t=top.read_text(); m=re.search(r'e203_subsys_main\s+u_e203_subsys_main\s*\(',t);assert m
 edit(top,m[0],m[0]+'\n .kwt_bus_rst_n(kwt_sys_rst_n),')
 edit(soc,'wire sysmem_icb_cmd_ready;', '''wire sysmem_icb_cmd_ready;
 wire kwt_sys_clk,kwt_sys_rst_n;
 wire [31:0] sysmem_addr,sysmem_wdata,sysmem_rdata;
 wire [3:0] sysmem_wmask;
 wire sysmem_read,sysmem_rvalid,sysmem_rready,sysmem_error;
 kwt_shared_sram u_kwt_shared_sram(
 .clk(kwt_sys_clk),.rst_n(kwt_sys_rst_n),
 .cmd_valid(sysmem_icb_cmd_valid),.cmd_ready(sysmem_icb_cmd_ready),
 .cmd_addr(sysmem_addr),.cmd_read(sysmem_read),.cmd_wdata(sysmem_wdata),.cmd_wmask(sysmem_wmask),
 .rsp_valid(sysmem_rvalid),.rsp_ready(sysmem_rready),.rsp_err(sysmem_error),.rsp_rdata(sysmem_rdata));''')
 edit(soc,'e203_subsys_top u_e203_subsys_top(','e203_subsys_top u_e203_subsys_top(\n .kwt_sys_clk(kwt_sys_clk),.kwt_sys_rst_n(kwt_sys_rst_n),')
 for port,value in [('cmd_read','sysmem_read'),('cmd_addr','sysmem_addr'),('cmd_wdata','sysmem_wdata'),('cmd_wmask','sysmem_wmask'),('rsp_valid','sysmem_rvalid'),('rsp_ready','sysmem_rready'),('rsp_err','sysmem_error'),('rsp_rdata','sysmem_rdata')]:
  s=soc.read_text();m=re.search(r'\.sysmem_icb_'+port+r'\s*\([^)]*\)',s);assert m
  edit(soc,m[0],'.sysmem_icb_'+port+'('+value+')')
 marker.write_text(json.dumps(changes,indent=2))

def image(elf):
 d=elf.read_bytes();assert d[:6]==b'\x7fELF\x01\x01'
 m=bytearray(65536);ph=struct.unpack_from('<I',d,28)[0];es,n=struct.unpack_from('<HH',d,42)
 for i in range(n):
  k,o,va,pa,s,ms,f,a=struct.unpack_from('<8I',d,ph+i*es)
  if k!=1 or not ms:continue
  off=pa-0x80000000;assert 0<=off and off+ms<=0x3000 and s<=ms
  m[off:off+s]=d[o:o+s]
 return m

def main():
 ap=argparse.ArgumentParser();ap.add_argument('--layers',nargs='+',type=int,default=[0]);ap.add_argument('--timeout',type=int,default=1800)
 ap.add_argument('--firmware',type=Path);ap.add_argument('--vcs')
 ap.add_argument('--flash-mode',choices=['single','quad'],default='single',help='original QSPI mode; quad requires matching quad firmware')
 ap.add_argument('--first-load-only',action='store_true')
 ap.add_argument('--macros',type=Path,help='official resources root, full technology macro simulation')
 ap.add_argument('--activity',action='store_true')
 ap.add_argument('--mapped-dir',type=Path,help='completed matching synthesis; functional gate simulation, no SDF')
 a=ap.parse_args();assert a.flash_mode=='single','GPIO runner does not accept QSPI mode';modify()
 out=P/'sim/results'/('sysbus_'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'));out.mkdir(parents=True)
 zig=TOOLS/'rv32_compiler/ziglang/zig.exe';iv=TOOLS/'iverilog/bin/iverilog.exe';vv=TOOLS/'iverilog/bin/vvp.exe'
 # Linux server tool paths may be supplied through normal PATH.
 cc=[str(zig),'cc','-target','riscv32-freestanding','-mcpu=baseline_rv32+m-c+zicsr'] if zig.exists() else ['riscv-nuclei-elf-gcc','-march=rv32im','-mabi=ilp32']
 def run(cmd,log,timeout):
  with log.open('wb') as f:r=subprocess.run(list(map(str,cmd)),cwd=P,stdout=f,stderr=subprocess.STDOUT,timeout=timeout)
  assert r.returncode==0,str(log)
 elf=out/'firmware.elf'
 fw=out/'firmware.verilog'
 if a.firmware:
  shutil.copy2(a.firmware,fw)
  raw=bytes(int(b,16) for b in fw.read_text().split());assert len(raw)==65536 and not any(raw[0x3000:])
 else:
  driver=(P/'sim/gpio_accept/driver.c')
  run(cc+['-mabi=ilp32','-msmall-data-limit=0','-mno-relax','-ffreestanding','-Isoftware/driver','-O2','-nostdlib','-Wl,-T,software/driver/soc_link.ld','software/driver/soc_start.S',driver,'-o',elf],out/'firmware_compile.log',120)
  fw.write_text('\n'.join('%02x'%b for b in image(elf))+'\n')
 rtl=P/'vendor/e203_hbirdv2/rtl/e203';tb=out/'tb_top.v'
 prepare_testbench(P/'vendor/e203_hbirdv2/tb/tb_top.v',tb,6.666666)
 s=tb.read_text();s=s.replace('module tb_top();','module tb_top();\n wire flash_sck,flash_cs,flash_mosi,flash_miso;\n wire [31:0] gpio_data,gpio_ack,gpio_oe; wire gpio_started; kwt_flash_source u_flash(flash_sck,flash_cs,flash_mosi,flash_miso,gpio_data,gpio_ack,gpio_oe,gpio_started,tb_top.clk);')
 for port,val in [('sck_o_oval','flash_sck'),('cs_0_o_oval','flash_cs'),('dq_0_o_oval','flash_mosi'),('dq_1_i_ival','flash_miso')]:
  pattern=r'(\.io_pads_qspi0_'+port+r'\s*)\([^)]*\)';s,n=re.subn(pattern,lambda m:m[1]+'('+val+')',s);assert n==1
 # Vendor timeout assumes short bare-metal smoke tests, not serial data loading.
 s=re.sub(r'#\s*2000000\s*;', '#200000000;',s)
 if a.flash_mode=='quad':
  s=s.replace('wire flash_sck,flash_cs,flash_mosi,flash_miso;', 'wire flash_sck,flash_cs,flash_mosi,flash_miso; wire [3:0] flash_dq;')
  s=s.replace('u_flash(flash_sck,flash_cs,flash_mosi,flash_miso);','u_flash(flash_sck,flash_cs,flash_mosi,flash_miso,flash_dq);')
  for i in [0,2,3]:
   s,n=re.subn(r'(\.io_pads_qspi0_dq_'+str(i)+r'_i_ival\s*)\([^)]*\)',lambda m:m[1]+'(flash_dq['+str(i)+'])',s);assert n==1

 for port,val in [('gpioA_i_ival','gpio_data'),('gpioB_o_oval','gpio_ack'),('gpioB_o_oe','gpio_oe')]:
  s,n=re.subn(r'(\.io_pads_'+port+r'\s*)\([^)]*\)',lambda m:m[1]+'('+val+')',s);assert n==1,(port,n)
 tb.write_text(s)
 flash=(P/'sim/gpio_accept/source.v')
 sources=[tb,flash,(P/'sim/gpio_accept/probe.v')]
 sources += [p for p in sorted(rtl.rglob('*.v')) if p.name not in ('e203_subsys_nice_core.v','config.v')]
 sources += [P/'rtl/acc'/n for n in ['e203_subsys_nice_core.v','kwt_nice.v','kwt_sram16.v','kwt_shared_sram.v','kwt_bus_dma.v']]
 if a.macros:
  assert a.vcs,'macro simulation requires VCS on the official server'
  from soc_macro_testbench import adapt_testbench
  from soc_technology import prepare_rom
  adapt_testbench(tb)
  resources=a.macros.resolve();mv=resources/'e203_hbirdv2-master'
  rom,_=prepare_rom(mv,out)
  excluded={'sirv_gnrl_ram.v','sirv_sim_ram.v','sirv_mrom_top.v','sirv_mrom.v','e203_clkgate.v'}
  sources=[f for f in sources if f.name not in excluded]
  sources += [P/'rtl/soc/kwt_platform_macros.v',P/'rtl/soc/kwt_mrom_top.v',rom]
  def one(pattern):
   candidates=list(resources.glob(pattern))+list(Path('/storage1/admin_public_dir/SRAM_Lib_2025').glob('*/verilog/'+pattern));assert len(candidates)==1,(pattern,candidates);return candidates[0]
  sources += [one(n+'.v') for n in ['RAMSP128X16','RAMSP1024X16','RAMSP4096X16']]
  sources += [one('e203_hbirdv2-master/rtl/e203/mem_gen/'+n+'/verilog/'+n+'.v') for n in ['RAMSP4KX64','RAMSP8KX32']]
  sources += [one('S40/smic/*/*/verilog/scc40nll_vhsc40_rvt.v')]
 if a.mapped_dir:
  assert a.macros,'mapped validation requires official macro models'
  mapped=a.mapped_dir.resolve();net=mapped/'soc_mapped.v'
  metadata=json.loads((mapped/'report.json').read_text())
  assert metadata['status']=='mapped_review_required',metadata['status']
  nt=net.read_text();ts=tb.read_text()
  # DC collapses generate scopes into escaped instance names.
  for name in sorted(set(re.findall(r'\\([^\s]+)\s',nt)),key=len,reverse=True):
   if '.u_ram' in name:
    ts=ts.replace('.'+name+'.mem','.'+chr(92)+name+' .mem')
  if chr(92)+'rf_r[3] ' in nt:
   ts=ts.replace('.rf_r[3]','.'+chr(92)+'rf_r[3] ')
  else:
   names=[chr(92)+'rf_r[3]['+str(bit)+'] ' for bit in reversed(range(32))]
   assert all(n in nt for n in names),'unrecognized mapped x3 register'
   word='{'+','.join('`EXU.u_e203_exu_regfile.'+n for n in names)+'}'
   ts=ts.replace('`EXU.u_e203_exu_regfile.rf_r[3]',word)
  tb.write_text(ts)
  sources=[tb,flash,(P/'sim/gpio_accept/probe.v'),net,rom]+[f for f in sources if f.name.startswith('RAMSP') or f.name=='scc40nll_vhsc40_rvt.v']
 inc=[v for p in [rtl/'core',rtl/'perips',rtl/'perips/apb_i2c'] for v in ['-I',str(p)]]
 binary=out/'soc.vvp'
 if a.vcs:
  binary=out/'soc.simv'
  vinc=['+incdir+'+str(p) for p in [rtl/'core',rtl/'perips',rtl/'perips/apb_i2c']]
  defines=['+define+KWT_SRAM_2025+ARM_UD_MODEL+functional'] if a.macros else ['+define+FPGA']
  run([a.vcs,'-full64','-sverilog','-timescale=1ns/1ps',*defines,'+define+DISABLE_SV_ASSERTION=1','-top','tb_top','-top','kwt_sysbus_probe','-Mdir='+str(out/'csrc'),'-o',binary,*vinc,*sources],out/'compile.log',600)
 else:
  run([str(iv) if iv.exists() else 'iverilog','-g2012','-DFPGA','-DDISABLE_SV_ASSERTION=1','-s','tb_top','-s','kwt_sysbus_probe','-o',binary,*inc,*sources],out/'compile.log',180)
 report={'scope':'Full E203 + original GPIO loading + original 32-bit SystemBus; SRAM mode recorded separately','firmware_sha256':hashlib.sha256(fw.read_bytes()).hexdigest(),'layers':[]}
 report.update(flash_mode=a.flash_mode,macros=bool(a.macros),timing_start='external GPIO sender begins driving first task word after original GPIO output-enable start',timing_end='second NICE response after output write acknowledgements',inputs={str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in sources})
 report['macro_simulation_mode']='official functional models, ARM_UD_MODEL + functional; no SDF timing acceptance' if a.macros else None
 report['mapped']=str(a.mapped_dir.resolve()) if a.mapped_dir else None
 for l in a.layers:
  log=out/f'L{l:02}.log'
  command=([binary] if a.vcs else [str(vv) if vv.exists() else 'vvp',binary])+['+TESTCASE='+fw.with_suffix('').relative_to(P).as_posix(),f'+LAYER={l}']
  if a.first_load_only:command+=['+FIRST_LOAD_ONLY']
  if a.activity:command+=['+ACTIVITY='+str(out/f'L{l:02}.vcd')]
  try:run(command,log,a.timeout)
  except Exception as e:print(e,flush=True)
  text=log.read_text(errors='replace');m=re.search(r'PASS SYSBUS layer=(\d+) cycles=(\d+)',text)
  failed=bool(re.search('FATAL|TEST_FAIL|Time Out',text))
  ok=bool(m) and 'TEST_PASS' in text and not failed
  if a.first_load_only:
   ok=text.count('FIRST_LOAD addr=')==3 and not failed
   report['scope']='first three loading words only; not full-output correctness or performance'
  row={'layer':l,'passed':ok,'cycles':int(m[2]) if m else None};report['layers'].append(row);print(row,flush=True)
  (out/'report.json').write_text(json.dumps(report,indent=2))
  if not ok:print(text[-5000:],flush=True);return 1
 return 0
if __name__=='__main__':sys.exit(main())


#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

# 只读同源产物，生成具名目标码索引；不把指令计数当作整链栈上界。
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'

options = {}
OptionParser.new do |parser|
  parser.banner = '用法：ruby Scripts/collect_playback_stack.rb --manifest 清单.json --output 新目录'
  parser.on('--manifest PATH', '含configuration/binary/binarySHA256/sourceRoot/sources的冻结清单') { |v| options[:manifest] = v }
  parser.on('--output PATH', '必须尚不存在的证据目录') { |v| options[:output] = v }
end.parse!
abort '必须给出manifest和output' unless options[:manifest] && options[:output]
abort '输出目录已存在，拒绝覆盖旧证据' if File.exist?(options[:output])

def command(*arguments, input: nil)
  output, error, status = Open3.capture3(*arguments, stdin_data: input.to_s)
  abort "工具失败（#{arguments.first}）：#{error}" unless status.success?
  [output, error]
end

manifest = JSON.parse(File.read(options[:manifest]))
%w[configuration binary binarySHA256 sourceRoot sources].each do |key|
  abort "清单缺少#{key}" unless manifest.key?(key)
end
abort 'sources必须为非空的相对路径→SHA256映射' unless manifest['sources'].is_a?(Hash) && !manifest['sources'].empty?
source_root = File.realpath(manifest['sourceRoot'])
manifest['sources'].each do |relative, expected|
  source = File.realpath(File.join(source_root, relative))
  abort "源码越出指定root：#{relative}" unless source.start_with?(source_root + File::SEPARATOR)
  abort "源码SHA不匹配：#{relative}" unless Digest::SHA256.file(source).hexdigest == expected
end
binary = File.realpath(manifest['binary'])
abort '产物SHA不匹配，禁止混用旧对象' unless Digest::SHA256.file(binary).hexdigest == manifest['binarySHA256']

tools = %w[llvm-nm llvm-objdump llvm-dwarfdump dwarfdump swift-demangle].to_h do |name|
  [name, command('xcrun', '--find', name).first.strip]
end
symbols = command(tools['llvm-nm'], '--defined-only', '--format=posix', binary).first.lines.each_with_object([]) do |line, result|
  fields = line.split
  result << fields.first if fields.length >= 3 && fields[1].match?(/\A[tT]\z/)
end
abort '未读到任何已定义text符号' if symbols.empty?
demangled = command(tools['swift-demangle'], '--compact', input: symbols.join("\n") + "\n").first.lines.map(&:strip)
abort 'demangle输出行数不一致' unless demangled.length == symbols.length
named = symbols.zip(demangled)
patterns = {
  'owner完成' => /PlaybackAudioSessionOwner\.receive\(/,
  'owner准备' => /PlaybackAudioSessionOwner\..*prepare(?:\(| in )/,
  'lane执行' => /AudioSessionBlockingCallLane\.execute\(/,
  'executor同步' => /PlaybackControlExecutor\.sync\(/,
  'Cell组合入口' => /SynchronousSafetyIngressCell\.performAudioSessionCall\(/,
  'Authority组合入口' => /ControlTaskRegistry\..*applyAudioSessionCall\(/,
  '准确claim' => /ControlTaskRegistry\..*claimStart\(/,
  '开始route采样' => /ControlTaskRegistry\..*beginOutputRouteSample\(/,
  'route到界' => /ControlTaskRegistry\..*timeoutOutputRouteBoundaryLocked\(/,
  '输出转换' => /ControlTaskRegistry\..*beginOutputTransitionLocked\(/,
  'reset完成' => /ControlTaskRegistry\..*settleOutputResetConfigurationActivation\(/,
  '原票退休' => /ControlTaskRegistry\..*prepareAndRetireOutputRecord\(/,
  '再次激活准备' => /ControlTaskRegistry\..*prepareReactivation\(/,
  '新cycle准备' => /ControlTaskRegistry\..*prepareOutputCycleLocked\(/,
  '命令准备' => /ControlTaskRegistry\..*prepareCommand\(/,
  '共享安装' => /ControlTaskRegistry\..*installPreparedCommand/,
  'Authority context getter' => /ControlTaskRegistry\..*Authority.*outputContext\.getter/,
  'Authority context setter' => /ControlTaskRegistry\..*Authority.*outputContext\.setter/,
  'resource context getter' => /OutputResourceState\.context\.getter/,
  'resource context setter' => /OutputResourceState\.context\.setter/
}
matches = patterns.transform_values { |pattern| named.select { |_, readable| readable.match?(pattern) } }
selected = matches.values.flatten(1).uniq
abort '全部具名函数均未匹配；不生成空表通过' if selected.empty?

FileUtils.mkdir_p(options[:output])
File.write(File.join(options[:output], 'manifest.json'), JSON.pretty_generate(manifest) + "\n")
{
  'uuid.txt' => [tools['dwarfdump'], '--uuid', binary],
  'platform.txt' => [tools['llvm-objdump'], '--macho', '--private-headers', binary],
  'unwind.txt' => [tools['llvm-objdump'], '--macho', '--unwind-info', binary],
  'eh-frame.txt' => [tools['llvm-dwarfdump'], '--eh-frame', binary]
}.each do |filename, arguments|
  output, diagnostics = command(*arguments)
  File.write(File.join(options[:output], filename), output + diagnostics)
end

rows = selected.each_with_index.map do |(symbol, readable), index|
  # Swift符号含$，作为独立argv传递，绝不经shell展开。
  assembly, diagnostics = command(tools['llvm-objdump'], '--disassemble', '--reloc', '--no-show-raw-insn',
    "--disassemble-symbols=#{symbol}", binary)
  instructions = assembly.lines.select { |line| line.match?(/^\s*[0-9a-fA-F]+:\s+\S+/) }
  abort "未取得具名函数完整指令：#{readable}（#{diagnostics.strip}）" if instructions.empty?
  filename = format('%03d.asm.txt', index + 1)
  File.write(File.join(options[:output], filename), "# #{readable}\n# #{symbol}\n" + assembly + diagnostics)
  # 这里只定位修改SP/调用的位置。条件路径、动态metadata、CFA与callee须人工合读完整函数。
  sp_sites = instructions.select do |line|
    line.match?(/\b(?:add|sub|mov|and)\s+sp,/) || line.match?(/\[sp(?:,[^\]]*)?\]!/) ||
      line.match?(/\[sp\],\s*#/)
  end
  calls = instructions.select { |line| line.match?(/\b(?:bl|blr|braa|brab|blraa|blrab|br)\s+/) }
  # 无条件b可能是函数内跳转，也可能是直接tail-call；保留目标交人工核验，不自动当callee。
  tails = instructions.select { |line| line.match?(/\bb\s+/) }
  { '函数' => readable, '符号' => symbol, '完整目标码' => filename,
    'SP修改候选' => sp_sites.map(&:strip), '调用及间接跳转候选' => calls.map(&:strip),
    '直接尾调用或函数内跳转候选（待核）' => tails.map(&:strip),
    '结论' => '仅具名位置索引；不是单帧数值或整链上界' }
end
unknown = matches.select { |_, values| values.empty? }.keys
File.write(File.join(options[:output], '调用与SP索引.json'), JSON.pretty_generate(rows) + "\n")
summary = [
  '# Playback 独立栈目标码证据', '',
  "配置：#{manifest['configuration']}；产物与#{manifest['sources'].length}份源码SHA已逐项核验。", '',
  "共提取#{rows.length}个具名函数/闭包，完整函数保存在对应asm文件，unwind与CFA另存。",
  'SP及调用索引仅供人工审阅，未将互斥路径或异步线程相加；未解析外部SDK/协议/间接callee不得视为0。', '',
  "未匹配（可能被内联/合并，当前未知）：#{unknown.empty? ? '无' : unknown.join('、')}。",
  '本工具只完成静态提取，不宣称行为、完整栈上界或Task6验收通过。', ''
].join("\n")
File.write(File.join(options[:output], '说明.md'), summary)
puts summary

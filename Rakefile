namespace :clean do
  task :all do
    sh 'rm -rf build'
  end

  task :cache do
    sh 'rm -rf build/cache'
  end

  task :plan do
    sh 'rm build/audit-plan.xml'
  end
end

directory 'build'
directory 'build/cache' => 'build'

file 'build/audit-plan.xml' => 'build/cache' do |f|
  ruby "build-audit-plan.rb #{f.name}"
end

task default: 'build/audit-plan.xml'

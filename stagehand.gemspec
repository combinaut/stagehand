$:.push File.expand_path("../lib", __FILE__)

# Maintain your gem's version:
require "stagehand/version"

# Describe your gem and declare its dependencies:
Gem::Specification.new do |s|
  s.name        = "culturecode_stagehand"
  s.version     = Stagehand::VERSION
  s.authors     = ["Nicholas Jakobsen", "Ryan Wallace"]
  s.email       = ["nicholas@culturecode.ca", "ryan@culturecode.ca"]
  s.homepage    = "https://github.com/culturecode/stagehand"
  s.summary     = "Simplify the management of a sandbox database that can sync content to a production database"
  s.description = "Simplify the management of a sandbox database that can sync content to a production database. Content changes can be bundled to allow partial syncs of the database."
  s.license     = "MIT"

  s.files = Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.rdoc"]

  s.add_dependency 'rails', '>= 4.2', '< 6.1'
  s.add_dependency 'mysql2'
  s.add_dependency 'ruby-graphviz'

  s.add_development_dependency 'combustion', '~> 1.3.0'
  s.add_development_dependency 'rspec-rails', '~> 3.7'
  s.add_development_dependency 'database_cleaner'
end

describe 'Stagehand::ActiveModelAliasAttributePatch' do
  # Rails 7.0 and earlier have neither the `aliases_by_attribute_name`
  # storage nor the `:id_value` auto-alias, so there is nothing to patch
  # and nothing to regress on.
  if ActiveModel::AttributeMethods::ClassMethods.method_defined?(:aliases_by_attribute_name)

    let(:klass) do
      Class.new do
        include ActiveModel::AttributeMethods
        define_attribute_methods :foo

        def attributes
          { 'foo' => nil }
        end
      end
    end

    it 'does not append a duplicate alias entry when called repeatedly with the same arguments' do
      klass.alias_attribute :bar, :foo
      klass.alias_attribute :bar, :foo
      klass.alias_attribute :bar, :foo

      aliases = klass.send(:aliases_by_attribute_name).fetch('foo', [])
      expect(aliases.count('bar')).to eq(1)
    end

    it 'still registers the alias on the first call' do
      klass.alias_attribute :bar, :foo

      expect(klass.attribute_aliases).to eq('bar' => 'foo')
      expect(klass.send(:aliases_by_attribute_name)['foo']).to eq(['bar'])
    end

  end
end

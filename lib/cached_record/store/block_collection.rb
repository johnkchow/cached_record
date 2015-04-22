class CachedRecord
  class Store
    class BlockCollection
      include Util::Assertion

      attr_reader :header, :store_adapter, :order, :block_size, :data_fetcher

      def initialize(header_key,
                     store_adapter:,
                     data_fetcher:,
                     order:,
                     block_size: CachedRecord.config.block_size)
        @store_adapter = store_adapter
        @data_fetcher = data_fetcher
        @block_size = block_size
        @order = order.to_sym
        @header_key = header_key
        @header = get_header(header_key)
      end

      def items(offset:, limit:)
        block_keys, start_index = header.block_keys_for_offset_limit(offset, limit)
        blocks = get_blocks(block_keys)

        # TODO: instead of concat, let's precalculate the returned
        # size from the meta data in the header block
        items = []
        items_left = limit

        first_block = blocks.first
        items.concat(first_block.values[start_index, items_left])

        items_left = limit - (first_block.count - start_index)
        blocks[1..-1].each do |block|
          items.concat(block.values[0, items_left])
          items_left -= block.count
        end
        items
      end

      def insert(meta_key, key, value)
        # if we have no blocks
        #   create new block
        #   insert value into that block
        # else if we find an existing block containing the key
        #   if count < size, return that block
        #   else
        #     generate 2 new blocks with new cache keys
        #     copy halves of the items from the original into the 2 blocks
        #     update the new blocks first_key and last_key
        #     replace the original metablock from header with new blocks info into header
        #     we need to split the block into half
        #     then determine if it lies within the first half block or 2nd half block
        #     update the headers meta block info for existing block
        #     save all 3 together
        # else if we find first block where max_key < key and count < size
        # else we find first block where key < min_key and count < size
        # else we create a new block
        #   if the key is less than min(min_keys)
        #   create new block, insert before all blocks
        #
        #   if the key is > max(min_keys)
        #   insert new block at the end of blocks

        if header.empty_blocks?
          block = create_new_block(meta_key, key, value)
          persist_block!(block)
        else
          meta_blocks = header.meta_blocks
          if meta_blocks.first.can_insert_before?(key)
            block = create_new_block(meta_key, key, value)
            persist_block!(block)
          else
            # NOTE: do binary search instead of linear
            meta_blocks.each_with_index do |meta_block, i|
              next_meta_block = meta_blocks[i + 1]

              if meta_block.include_key?(key)
                insert_within_block!(meta_block, meta_key, key, value)
                break
              elsif !meta_block.full? && (!next_meta_block || next_meta_block.can_insert_before?(key))
                insert_within_block!(meta_block, meta_key, key, value)
                break
              elsif meta_block.can_insert_between?(key, next_meta_block)
                block = create_new_block(meta_key, key, value)
                persist_block!(block)
                break
              end
            end
          end
        end
        persist_header!
      end

      def find
        found_block = nil
        found_index = nil
        header.meta_blocks.each do |meta_block|
          block = get_block(meta_block.key)
          block.values.each_with_index do |item, i|
            if yield(item)
              found_block = block
              found_index = i
              break
            end
          end
        end

        if found_block
          CachedRecord::Store::ManagedItem.new(
            store: self,
            block: found_block,
            index: found_index,
          )
        end
      end

      # Takes a block that must take in a value and return a boolean value
      def remove
        raise NotImplementedError, "todo"
        # loop through all the meta blocks
        #   fetch the block
        #   loop through all items in the block
        #   if the conditional returns true, remove the item
        #
        # NOTE: should we compact here? This is probably the easiest to do, since
        # compacting is only necessary when removing items, as keys may be unbalanced
        #
        # rebalance keys/items if necessary with surrounding blocks
      end


      protected

      attr_reader :header_key

      def persist_header!
        store_adapter.write(header.key, header.to_hash)
      end

      def persist_block!(block)
        store_adapter.write(block.key, block.to_hash)
      end

      def create_new_block(meta_key, key, value)
        block = build_block(nil, keys: [key], values: [value])
        header.create_block(
          block_key: block.key,
          key: key,
          meta_key: meta_key
        )

        block
      end

      def insert_within_block!(meta_block, meta_key, key, value)
        block = get_block(meta_block.key)
        if meta_block.should_resize?
          split_meta_blocks = header.split_meta_block(meta_block.key)
          blocks = split_block(block)

          inserted = false

          blocks.each_with_index do |b, index|
            meta_block = split_meta_blocks[index]

            meta_block.key = b.key
            if !inserted && b.key_within_range?(key)
              index = b.insert(key, value)
              meta_block.insert(meta_key, key, index)
              inserted = true
            end
            persist_block!(b)
          end
        else
          index = block.insert(key, value)
          meta_block.insert(meta_key, key, index)

          persist_block!(block)
        end
      end

      def split_block(block)
        min_key, max_key = build_block_key, build_block_key

        block.split(min_key, max_key)
      end

      def get_block(key)
        get_blocks([key]).first
      end

      def get_blocks(keys)
        ordered_blocks = Array.new(keys.length)
        keys_to_index = {}

        keys.each_with_index do |k, i|
          keys_to_index[k] = i
        end

        raw_blocks = store_adapter.read_multi(*keys)

        if raw_blocks.any? {|k,v| v.nil? }
          unfound_block_keys = raw_blocks.inject([]) do |arr, (k, v)|
            arr << k if v.nil?
            arr
          end

          unfound_block_keys.each do |block_key|
            meta_keys = header.meta_keys_for_block_key(block_key)
            block_keys, block_values = data_fetcher.fetch_key_values(meta_keys)

            block = build_block(block_key, keys: block_keys, values: block_values)
            persist_block!(block)

            ordered_blocks[keys_to_index[block_key]] = block
          end
        end
        raw_blocks.each do |key, raw_block|
          if raw_block
            block = build_block(key, raw_block)

            ordered_blocks[keys_to_index[key]] = block
          end
        end
        ordered_blocks
      end

      def build_block(key, raw_block)
        data = {order: order, size: block_size}.merge(raw_block)
        key ||= build_block_key
        Block.new(key, data)
      end

      def build_block_key
        "#{header_key}:block:#{SecureRandom.uuid}"
      end

      def get_header(key)
        header_data = store_adapter.read(key) || fetch_header_attributes
        Header.new(header_data.merge(key: key))
      end

      def fetch_header_attributes
        meta_keys = data_fetcher.fetch_meta_keys
        blocks = meta_keys.each_slice(block_size).inject([]) do |arr, keys_data|
          arr << {
            key: build_block_key,
            size: block_size,
            keys_data: keys_data
          }
        end

        {
          order: order,
          blocks: blocks,
        }
      end
    end
  end
end

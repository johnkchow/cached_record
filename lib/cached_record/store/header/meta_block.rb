class CachedRecord
  class Store
    class Header
      class MetaBlock
        include CachedRecord::Model::Fields
        include CachedRecord::Store::SplitArray

        field :key, :size, :keys_data

        attr_reader :order

        def initialize(data, order)
          super(data)
          @order = order
          raise ArgumentError, "Unknown order #{order}" unless [:desc, :asc].include?(order)
        end

        def full?
          count == size
        end

        def include_key?(key)
          case order
          when :asc
            (min_key <= key && key <= max_key)
          when :desc
            (min_key >= key && key >= max_key)
          end
        end

        def min_key
          if data = keys_data.first
            data[:key]
          end
        end

        def delete_at(index)
          keys_data.delete_at(index)
        end

        def max_key
          if data = keys_data.last
            data[:key]
          end
        end

        def count
          keys_data.length
        end

        def insert(meta_key, key, index)
          keys_data.insert(index, key: key, meta: meta_key)
        end

        def can_insert_or_split?(key)
          # NOTE: the !full? conditional is dependent that no key block ranges overlap
          # and the only block with available slots is the only block with available
          # slots. Otherwise, we may run into key overlapping issues, which will mess
          # with ordering/fetching.
          include_key?(key) || !full?
        end

        def split
          first, last = split_array(keys_data)
          [
            self.class.new({
              size: size,
              keys_data: first,
            }, order),
            self.class.new({
              size: size,
              keys_data: last,
            }, order),
          ]
        end

        def can_insert_before?(key)
          return false if full?

          case order
          when :asc
            key < min_key
          when :desc
            key > min_key
          end
        end

        def can_insert_between?(key, other_block)
          return false unless self.full? && other_block.full?

          block1, block2 = sort_blocks(self, other_block)

          case order
          when :asc
            block1.max_key < key && key < block2.min_key
          when :desc
            block1.max_key > key && key > block2.min_key
          end
        end

        def find_by_meta
          keys_data.each_with_index do |kd, i|
            if yield(kd[:meta])
              return i
            end
          end

          nil
        end

        def should_resize?
          count >= size
        end

        protected

        def sort_blocks(block1, block2)
          blocks = if block1.max_key <= block2.max_key && block1.min_key <= block2.min_key
                     [block1, block2]
                   else
                     [block2, block1]
                   end
          blocks.reverse! if order == :desc
          blocks
        end
      end
    end
  end
end

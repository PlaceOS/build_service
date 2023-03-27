module PlaceOS::Api
  class Error < Exception
    getter message

    def initialize(@message : String = "")
      super(message)
    end

    class Unauthorized < Error
    end

    class NotFound < Error
    end

    class CompileError < Error
    end
  end
end

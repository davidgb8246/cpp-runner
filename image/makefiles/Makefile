CXX = g++
CXXFLAGS = -std=c++17 -Wall -Wno-deprecated -O2
CPPFLAGS = $(shell find . -type d -not -path './.git*' -not -path './build*' | sed 's|^.|-I.|')

SOURCES = $(shell find . -type f -name '*.cpp' -not -path './.git/*' -not -path './build/*' | sort)
OBJECTS = $(SOURCES:.cpp=.o)

all: a.out

a.out: $(OBJECTS)
	$(CXX) $(OBJECTS) -o $@

%.o: %.cpp
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -c $< -o $@

clean:
	rm -f $(OBJECTS) a.out

.PHONY: all clean

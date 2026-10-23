# gen.mk -- se carga JUNTO a "Makefile" (make -f Makefile -f gen.mk gen GEN_OUT=...)
# Reutiliza las variables del Makefile de referencia (CXX, CXXFLAGS, CPPFLAGS, SOURCES)
# para que el Makefile estático salga exactamente de su misma lógica.

TAB := $(shell printf '\t')

define STATIC_MAKEFILE
# Makefile estático generado automáticamente a partir de la lógica de "Makefile".
# Las rutas (includes y fuentes) están fijadas en el momento de la generación.
# Si añades o mueves ficheros, vuelve a generarlo.
CXX = $(CXX)
CXXFLAGS = $(CXXFLAGS)
CPPFLAGS = $(CPPFLAGS)

SOURCES = $(SOURCES)
OBJECTS = $$(SOURCES:.cpp=.o)

all: a.out

a.out: $$(OBJECTS)
$(TAB)$$(CXX) $$(OBJECTS) -o $$@

%.o: %.cpp
$(TAB)$$(CXX) $$(CPPFLAGS) $$(CXXFLAGS) -c $$< -o $$@

clean:
$(TAB)rm -f $$(OBJECTS) a.out

.PHONY: all clean
endef

$(file >$(GEN_OUT),$(STATIC_MAKEFILE))

gen: ;@:

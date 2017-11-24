// COMS20001 - Cellular Automaton Farm - Initial Code Skeleton
// (using the XMOS i2c accelerometer demo code)

#include <platform.h>
#include <xs1.h>
#include <stdio.h>
#include "pgmIO.h"
#include "i2c.h"

#define IN_FILE_NAME "128x128.pgm"
#define OUT_FILE_NAME "testout.pgm"

#define  IMHT 128                  //image height
#define  IMWD 128                  //image width
#define  PROCESS_THREAD_COUNT 4
#define  ROWS_PER_THREAD 32
#define  NUM_INTS_PER_ROW 4
#define  MAX_ITERATIONS 0          // 0 to make it run indefinitely

struct carry {
    unsigned int value;
    unsigned int carryOut;
};
typedef struct carry carry;
typedef unsigned char uchar;      //using uchar as shorthand

on tile[0] : in port buttons = XS1_PORT_4E; //port to access xCore-200 buttons
on tile[0] : out port leds = XS1_PORT_4F;   //port to access xCore-200 LEDs
on tile[0]: port p_scl = XS1_PORT_1E;         //interface ports to orientation
on tile[0]: port p_sda = XS1_PORT_1F;

#define FXOS8700EQ_I2C_ADDR 0x1E  //register addresses for orientation
#define FXOS8700EQ_XYZ_DATA_CFG_REG 0x0E
#define FXOS8700EQ_CTRL_REG_1 0x2A
#define FXOS8700EQ_DR_STATUS 0x0
#define FXOS8700EQ_OUT_X_MSB 0x1
#define FXOS8700EQ_OUT_X_LSB 0x2
#define FXOS8700EQ_OUT_Y_MSB 0x3
#define FXOS8700EQ_OUT_Y_LSB 0x4
#define FXOS8700EQ_OUT_Z_MSB 0x5
#define FXOS8700EQ_OUT_Z_LSB 0x6

void processGame(char workerID, chanend fromDistributor, chanend topChannel, chanend bottomChannel);
unsigned int parseRowToInt(int rowNumber);
unsigned int generateNewRow(unsigned int top, unsigned int self, unsigned int bottom, int length);
carry carryLeftShift(unsigned int input, unsigned int carryIn, int length);
carry carryRightShift(unsigned int input, unsigned int carryIn, int length);
void leftShiftLargeRow(int totalLength, unsigned int row[NUM_INTS_PER_ROW]);
void addToLargeRow(char* original, unsigned int added[NUM_INTS_PER_ROW], int totalLength);
void addThreeLargeRows(char* original, unsigned int added[NUM_INTS_PER_ROW], int totalLength);
void processLargeGame(char workerID, chanend fromDistributor, chanend topChannel, chanend bottomChannel);
void generateNewLargeRow(unsigned int top[NUM_INTS_PER_ROW], unsigned int self[NUM_INTS_PER_ROW], unsigned int bottom[NUM_INTS_PER_ROW], unsigned int result[NUM_INTS_PER_ROW], int totalLength);
/////////////////////////////////////////////////////////////////////////////////////////
//
// Read Image from PGM file from path infname[] to channel c_out
//
/////////////////////////////////////////////////////////////////////////////////////////
void DataInStream(char infname[], chanend c_out)
{
  int res;
  uchar line[ IMWD ];
  printf( "DataInStream: Start...\n" );

  //Open PGM file
  res = _openinpgm( infname, IMWD, IMHT );
  if( res ) {
    printf( "DataInStream: Error openening %s\n.", infname );
    return;
  }

  //Read image line-by-line and send byte by byte to channel c_out
  for( int y = 0; y < IMHT; y++ ) {
    _readinline( line, IMWD );
    for( int x = 0; x < IMWD; x++ ) {
      c_out <: line[ x ];
      printf( "-%4.1d ", line[ x ] ); //show image values
    }
    printf( "\n" );
  }

  //Close PGM image file
  _closeinpgm();
  printf( "DataInStream: Done...\n" );
  return;
}

void stateManager(chanend fromAcc, chanend toDistributor) {
    unsigned char state = 0;
    unsigned char previousState = 0;
    unsigned int numRoundsProcessed = 0;
    int pressedButton = 0;

        buttons when pinseq(13)  :> pressedButton;

    while (1) {
        buttons when pinsneq(13)  :> pressedButton;
        fromAcc :> state;
        if (state == 0 && previousState == 2) state = 3; // Give one-time unpause
        if (pressedButton == 14 && state != 2 && previousState != 1) {
            state = 1;
            pressedButton = 0;
        }
        numRoundsProcessed += 1;
        if (numRoundsProcessed == MAX_ITERATIONS) state = 1;
        previousState = state;
        toDistributor <: state;
        //printf("Current state: %d\n", state);
    }
}
/////////////////////////////////////////////////////////////////////////////////////////
//
// Start your implementation by changing this function to implement the game of life
// by farming out parts of the image to worker threads who implement it...
// Currently the function just inverts the image
//
/////////////////////////////////////////////////////////////////////////////////////////
void distributor(chanend c_in, chanend c_out, chanend fromStateManager)
{
  timer t;
  unsigned int time = 0;
  unsigned int newTime = 0;
  unsigned int overflows = 0;
  unsigned int numRoundsProcessed = 0;
  uchar val;
  //Starting up and wait for tilting of the xCore-200 Explorer
  printf( "ProcessImage: Start, size = %dx%d\n", IMHT, IMWD );
  printf( "Waiting for Board Tilt...\n" );
  fromStateManager :> char value;

  printf( "Processing...\n" );

  chan rowChannels[PROCESS_THREAD_COUNT];
  chan distributorChannels[PROCESS_THREAD_COUNT];
  unsigned char state = 0;
  int ledPattern = 0;
  int led1On = 0;
  par {
      // Worker threads
      par (int i = 0; i < PROCESS_THREAD_COUNT; i++) {
            processLargeGame(i, distributorChannels[i], rowChannels[i],rowChannels[(i+1)%PROCESS_THREAD_COUNT]);
      }
      // Distributor state handling
      {
          {
              leds <: 4;
              for (int j = 0; j < PROCESS_THREAD_COUNT; j++) {
                    for (int k = 0; k < ROWS_PER_THREAD; k++) {
                        for (int l = 0; l < NUM_INTS_PER_ROW; l++) {
                            unsigned int currentRow = 0;
                            int maxIntSize = 32;
                            if (IMWD < 32) maxIntSize = IMWD;
                            for( int x = 0; x < maxIntSize; x++ ) {                    // Go through each pixel per line
                                c_in :> val;                                   // Read the pixel value
                                if (val == 0xFF) currentRow = currentRow | 1;  // Put pixel on the end of the int
                                currentRow = currentRow << 1;                  // Shift int to the left
                            }
                            distributorChannels[j] <: currentRow;
                        }
                    }
               }
              leds <: 0;
          }
          while (1) {
              fromStateManager :> state;
              t :> newTime;
              if (time > newTime) overflows++;
              time = newTime;

//              select{
//                  case t when timerafter (time + 100000) :> newTime :
//                      time = newTime;
//                      break;
//              }

              switch (state) {
                  case 0:
                      if (led1On == 1) led1On = 0;
                      else led1On = 1;
                      ledPattern = led1On;
                      leds <: ledPattern;
                      for (int n = 0; n < PROCESS_THREAD_COUNT; n++) {
                          distributorChannels[n] <: state;
                      }
                      break;
                  case 1:
                      ledPattern = 2;
                      leds <: ledPattern;
                      for (int n = 0; n < PROCESS_THREAD_COUNT; n++) {
                          distributorChannels[n] <: state;
                      }
                      // Data workers -> output thread
                      for (int j = 0; j < PROCESS_THREAD_COUNT; j++) {
                          for (int k = 0; k < ROWS_PER_THREAD; k++) {
                              for (int l = 0; l < NUM_INTS_PER_ROW; l++) {
                                  unsigned int currentRowPart = 0;
                                  distributorChannels[j] :> currentRowPart;
                                  int maxIntSize = 32;
                                  if (IMWD < 32) maxIntSize = IMWD;
                                  for( int x = 0; x < maxIntSize; x++ ) {
                                      char pixelVal = 0;
                                      char bitVal = (currentRowPart & (1 << (maxIntSize-1))) >> (maxIntSize-1); // Check pixel at the start (most significant part) of the int
                                      if (bitVal == 1) pixelVal = 0xFF;                                         // Convert bit value to pixel value
                                      currentRowPart = currentRowPart << 1;                                     // Shift int to the left
                                      c_out <: pixelVal;                                                        // Print pixel to outstream
                                  }
                              }
                          }
                      }
                      break;
                  case 2:
                      unsigned int numLiveCells = 0;
                      ledPattern = 8;
                      leds <: ledPattern;
                      for (int j = 0; j < PROCESS_THREAD_COUNT; j++) {
                          for (int k = 0; k < ROWS_PER_THREAD; k++) {
                              for (int l = 0; l < NUM_INTS_PER_ROW; l++) {
                                  unsigned int currentRowPart = 0;
                                  distributorChannels[j] :> currentRowPart;
                                  int maxIntSize = 32;
                                  if (IMWD < 32) maxIntSize = IMWD;
                                  for( int x = 0; x < maxIntSize; x++ ) {
                                      char bitVal = (currentRowPart & (1 << (maxIntSize-1))) >> (maxIntSize-1); // Check cell at the start (most significant part) of the int
                                      if (bitVal == 1) numLiveCells += 1;
                                      currentRowPart = currentRowPart << 1;                                     // Shift int to the left
                                  }
                              }
                          }
                      }
                      printf("Number of processing rounds completed: %d \n", numRoundsProcessed);
                      printf("Number of live cells: %d \n", numLiveCells);
                      unsigned int stime = overflows * ( INT_MAX / 100000000) + newTime / 100000000;
                      unsigned int mstime = (overflows * ( INT_MAX % 100000000) + newTime % 100000000)/ 100000;
                      if (mstime > 1000) {
                          stime += mstime / 1000;
                          mstime = mstime % 1000;
                      }
                      printf("Processing time elapsed since read-in: %d seconds %d milliseconds. \n", stime, mstime);
                      for (int m = 0; m < PROCESS_THREAD_COUNT; m++) {
                          distributorChannels[m] <: state;
                      }
                      break;
                  case 3:
                      led1On = 1;
                      ledPattern = led1On;
                      leds <: ledPattern;
                      for (int n = 0; n < PROCESS_THREAD_COUNT; n++) {
                          distributorChannels[n] <: state;
                      }
                      break;
              }
              numRoundsProcessed += 1;
          }
      }
  }
}
/*void processGame(char workerID, chanend fromDistributor, chanend topChannel, chanend bottomChannel) {
    unsigned int oldRowData[ROWS_PER_THREAD + 2];
    unsigned int newRowData[ROWS_PER_THREAD + 2];
    for (int j = 1; j <= ROWS_PER_THREAD; j++) {
        fromDistributor :> oldRowData[j];
    }
    while(1) {
        if (workerID % 2 == 0) {
            // Even-numbered channels send data upwards then downwards to odd-numbered channels
            // This means that odd-numbered channels receive first from the bottom then the top
            topChannel    <: oldRowData[1];
            bottomChannel <: oldRowData[ROWS_PER_THREAD];
            // Then they receive from the bottom first then top
            bottomChannel :> oldRowData[ROWS_PER_THREAD + 1];
            topChannel    :> oldRowData[0];
        } else {
            // Odd-numbered channels receive data from the bottom, then the top
            bottomChannel :> oldRowData[ROWS_PER_THREAD + 1];
            topChannel    :> oldRowData[0];
            // Then they take their round transmitting towards the top, then the bottom
            topChannel    <: oldRowData[1];
            bottomChannel <: oldRowData[ROWS_PER_THREAD];
        }
        for (int k = 1; k <= ROWS_PER_THREAD; k++) {
            newRowData[k] = generateNewRow(oldRowData[k-1],oldRowData[k],oldRowData[k+1],IMWD);
        }
        for (int l = 1; l <= ROWS_PER_THREAD; l++) {
            oldRowData[l] = newRowData[l];
        }
        // Give commands to worker process on how to proceed further
        unsigned char nextCommand = 0;
        fromDistributor :> nextCommand;
        switch (nextCommand) {
            case 1:
                for (int j = 1; j <= ROWS_PER_THREAD; j++) {
                    fromDistributor <: oldRowData[j];
                }
                break;
            case 2:
                unsigned char delayed = 0;
                while (delayed != 3) {
                    fromDistributor :> delayed;
                }
                break;
        }
        // Listen to the distributor channel
        // 0 -> continue as normal
        // 1 -> do a data output
        // 2 -> stop until...
        // 3 -> this is received; start processing again
    }
}*/
void processLargeGame(char workerID, chanend fromDistributor, chanend topChannel, chanend bottomChannel) {
    unsigned int oldRowData[ROWS_PER_THREAD + 2][NUM_INTS_PER_ROW];
    unsigned int newRowData[ROWS_PER_THREAD + 2][NUM_INTS_PER_ROW];
    for (int j = 1; j <= ROWS_PER_THREAD; j++) {
        for (int i = 0; i < NUM_INTS_PER_ROW; i++) {
            fromDistributor :> oldRowData[j][NUM_INTS_PER_ROW - i - 1];
        }
    }
    while(1) {
        if (workerID % 2 == 0) {
            for (int h = 0; h < NUM_INTS_PER_ROW; h++) {
                topChannel    <: oldRowData[1][h];
                bottomChannel <: oldRowData[ROWS_PER_THREAD][h];
                bottomChannel :> oldRowData[ROWS_PER_THREAD + 1][h];
                topChannel    :> oldRowData[0][h];
            }
        } else {
            for (int g = 0; g < NUM_INTS_PER_ROW; g++) {
                bottomChannel :> oldRowData[ROWS_PER_THREAD + 1][g];
                topChannel    :> oldRowData[0][g];
                topChannel    <: oldRowData[1][g];
                bottomChannel <: oldRowData[ROWS_PER_THREAD][g];
            }
        }
        for (int k = 1; k <= ROWS_PER_THREAD; k++) {
            generateNewLargeRow(oldRowData[k-1], oldRowData[k], oldRowData[k+1], newRowData[k],IMWD);
        }
        for (int y = 0; y < ROWS_PER_THREAD; y++) {
            for (int z = 0; z < NUM_INTS_PER_ROW; z++) {
                oldRowData[y][z] = newRowData[y][z];
            }
        }
        unsigned char nextCommand = 0;
        fromDistributor :> nextCommand;
        switch (nextCommand) {
            case 1:
                for (int j = 1; j <= ROWS_PER_THREAD; j++) {
                    for (int d = 0; d < NUM_INTS_PER_ROW; d++) {
                        fromDistributor <: newRowData[j][d];
                    }
                }
                break;
            case 2:
                for (int j = 1; j <= ROWS_PER_THREAD; j++) {
                    for (int d = 0; d < NUM_INTS_PER_ROW; d++) {
                        fromDistributor <: newRowData[j][d];
                    }
                }
                unsigned char delayed = 0;
                while (delayed != 3) {
                    fromDistributor :> delayed;
                }
                break;
        }
    }
}
// Circular left shift the bits in an int value that uses 'size' number of bits
unsigned int circularLeftShift(unsigned int input, int length) {
    unsigned int result = input << 1 | input >> (length-1);
    // Mask unneeded values
    unsigned int mask = 0xFFFFFFFF >> (32-length);
    result = result & mask;
    return result;
}
carry carryLeftShift(unsigned int input, unsigned int carryIn, int length) {
    unsigned int outResult = input >> (length-1);
    unsigned int result = input << 1 | carryIn;
    // Mask unneeded values
    unsigned int mask = 0xFFFFFFFF >> (32-length);
    result = result & mask;
    carry resultCarry;
    resultCarry.value = result;
    resultCarry.carryOut = outResult;
    return resultCarry;
}
void leftShiftLargeRow(int totalLength, unsigned int row[NUM_INTS_PER_ROW]) {
    int currentLength = 0;
    int i = NUM_INTS_PER_ROW-1;
    carry currentCarry;
    unsigned int lastLength = totalLength % 32;
    if (lastLength == 0) lastLength = 32;
    unsigned int lastInt = row[0];
    unsigned int carryIn = lastInt >> (lastLength - 1);
    while (totalLength > 0) {
        if (totalLength >= 32) currentLength = 32;
        else currentLength = totalLength;
        totalLength -= currentLength;
        currentCarry = carryLeftShift(row[i], carryIn, currentLength);
        row[i] = currentCarry.value;
        carryIn = currentCarry.carryOut;
        i -= 1;
    }
}
// Circular right shift the bits in an int value that uses 'size' number of bits
unsigned int circularRightShift(unsigned int input, int length) {
    unsigned int result = input >> 1 | input << (length-1);
    // Mask unneeded values
    unsigned int mask = 0xFFFFFFFF >> (32-length);
    result = result & mask;
    return result;
}
carry carryRightShift(unsigned int input, unsigned int carryIn, int length) {
    unsigned int outResult = input & 1;
    unsigned int result = input >> 1 | (carryIn << (length-1));
    // Mask unneeded values
    unsigned int mask = 0xFFFFFFFF >> (32-length);
    result = result & mask;
    carry resultCarry;
    resultCarry.value = result;
    resultCarry.carryOut = outResult;
    return resultCarry;
}
void rightShiftLargeRow(int totalLength, unsigned int row[NUM_INTS_PER_ROW]) {
    int currentLength = 0;
    int i = 0;
    carry currentCarry;
    unsigned int lastInt = row[NUM_INTS_PER_ROW - 1];
    unsigned int carryIn = lastInt & 1;
    while (totalLength > 0) {
        if (totalLength % 32 == 0) currentLength = 32;
        else currentLength = totalLength % 32;
        totalLength -= currentLength;
        currentCarry = carryRightShift(row[i], carryIn, currentLength);
        row[i] = currentCarry.value;
        carryIn = currentCarry.carryOut;
        i += 1;
    }
}
char determineLifeState(unsigned int currentState, char counter) {
    char resultState = 0;
    if (currentState == 0 && counter == 3)     resultState = 1; // Dead with 3 neighbours becomes alive
    else if (currentState == 1 && counter < 2) resultState = 0; // Living with <2 neighbours dies
    else if (currentState == 1 && counter > 3) resultState = 0; // Living with 3> neighbours dies
    else if (currentState == 1)                resultState = 1; // Living with 2/3 neighbours lives
    else                                       resultState = 0; // Dead anything else stays dead
    return resultState;
}
void addToRow(char* original, unsigned int added, int length) {
    unsigned int addedCopy = added;
    for (int i = 0; i < length; i++) {
        // Take the least significant bit (from the rightmost side) and add to row
        original[i] += addedCopy & 1;
        // Shift it to the right to delete the least significant bit
        addedCopy = addedCopy >> 1;
    }
}
void addToLargeRow(char* original, unsigned int added[NUM_INTS_PER_ROW], int totalLength) {
    int indexInOriginal = 0;
    unsigned int currentLength;
    for (int i = 0; i < NUM_INTS_PER_ROW; i++) {
        if (totalLength >= 32) currentLength = 32;
        else currentLength = totalLength;
        totalLength -= currentLength;
        unsigned int addedCopy = added[i];
        for (int j = 0; j < currentLength; j++) {
            indexInOriginal = i * 32 + j;
            original[indexInOriginal] += addedCopy & 1;
            addedCopy = addedCopy >> 1;
        }
    }
}
void addThreeLargeRows(char* original, unsigned int added[NUM_INTS_PER_ROW], int totalLength) {
    unsigned int selfCopyLeft[NUM_INTS_PER_ROW];
    unsigned int selfCopyRight[NUM_INTS_PER_ROW];
    for (int x = 0; x < NUM_INTS_PER_ROW; x++) {
        selfCopyLeft[x] = added[x];
        selfCopyRight[x] = added[x];
    }
    leftShiftLargeRow(totalLength, selfCopyLeft);
    rightShiftLargeRow(totalLength, selfCopyRight);
    addToLargeRow(original, selfCopyLeft, totalLength);
    addToLargeRow(original, selfCopyRight,totalLength);
    addToLargeRow(original, added,        totalLength);
}
void addThreeRows(char* original, unsigned int added, int length) {
    unsigned int leftShifted = circularLeftShift(added, length);
    unsigned int rightShifted = circularRightShift(added, length);
    addToRow(original, leftShifted, length);
    addToRow(original, added, length);
    addToRow(original, rightShifted, length);
}
void generateNewLargeRow(unsigned int top[NUM_INTS_PER_ROW], unsigned int self[NUM_INTS_PER_ROW], unsigned int bottom[NUM_INTS_PER_ROW], unsigned int result[NUM_INTS_PER_ROW], int totalLength) {
        unsigned int selfCopyLeft[NUM_INTS_PER_ROW];
        unsigned int selfCopyRight[NUM_INTS_PER_ROW];
        for (int x = 0; x < NUM_INTS_PER_ROW; x++) {
            selfCopyLeft[x] = self[x];
            selfCopyRight[x] = self[x];
        }
        leftShiftLargeRow(totalLength, selfCopyLeft);
        rightShiftLargeRow(totalLength, selfCopyRight);
        char newRowCount[IMWD];
        for (int i = 0; i < totalLength; i++) newRowCount[i] = 0;
        addToLargeRow(newRowCount, selfCopyLeft, totalLength);
        addToLargeRow(newRowCount, selfCopyRight, totalLength);
        addThreeLargeRows(newRowCount, top, totalLength);
        addThreeLargeRows(newRowCount, bottom, totalLength);

        unsigned int currentLength = 0;
        char pretendNewRow[32];
        for (int i = 0; i < NUM_INTS_PER_ROW; i++) {
            if (totalLength >= 32) currentLength = 32;
            else currentLength = totalLength % 32;
            totalLength -= currentLength;
            for (int j = 0; j < 32; j++) {
                pretendNewRow[j] = newRowCount[i * 32 + j];
            }
            unsigned int selfCopy = self[NUM_INTS_PER_ROW - i - 1];
            unsigned int newRow = 0;
            for (int p = 0; p < currentLength; p++) {
                unsigned int currentState = (selfCopy & (1 << (currentLength-1))) >> (currentLength-1);
                char result = determineLifeState(currentState, pretendNewRow[currentLength-p-1]);
                if (result == 1) newRow = newRow | 1;
                if (p != currentLength-1) newRow = newRow << 1;
                selfCopy = selfCopy << 1;
            }
            result[NUM_INTS_PER_ROW - i - 1] = newRow;
        }
}
unsigned int generateNewRow(unsigned int top, unsigned int self, unsigned int bottom, int length) {
    unsigned int newRow = 0;
    unsigned int selfCopy = self;
    // Initialize new counter array for determining tile states
    char newRowCount[32];
    for (int i = 0; i < length; i++) newRowCount[i] = 0;
    // Add right side neighbours' states
    addToRow(newRowCount, circularLeftShift(selfCopy, length), length);
    // Add left side neighbours' states
    addToRow(newRowCount, circularRightShift(selfCopy, length), length);
    // Add top and top diagonals states
    addThreeRows(newRowCount, top, length);
    // Add bottom and bottom diagonals states
    addThreeRows(newRowCount, bottom, length);
    // Once all the neighbours have been counted, proceed to determining life states

    for (int j = 0; j < length; j++) {
        // Get most significant bit (on the leftmost side)
        unsigned int currentState = (selfCopy & (1 << (length-1))) >> (length-1);
        // Determine whether tile is alive or not
        char result = determineLifeState(currentState, newRowCount[length-j-1]);
        // If the result is alive, put a 1 on the least significant bit (the shift below will make it more significant)
        if (result == 1) newRow = newRow | 1;
        // Store the new value by shifting the result left
        if (j != length-1) newRow = newRow << 1;
        // Expose a new value at the most significant place by shifting the original's copy left
        selfCopy = selfCopy << 1;
    }
    return newRow;
}

/*int assertEqual(int first, int second, int testNum) {
    if (first == second) {
        //printf("TEST %d SUCCESSFUL\n", testNum);
        return 1;
    }
    else {
        printf("TEST %d FAILED. Expected: %d, got: %d\n", testNum, first, second);
        return 0;
    }
}*/
/*void runTests() {
    //BIT SHIFTING
    int bitTestTotal = 0;

    //Two commented out tests fail, they are ints which are larger than 32 bit
    //This ultimately is a flaw in the int type, not our code
    //So not sure how big a problem this is, as length is set by IMWD
    bitTestTotal += assertEqual(2, circularLeftShift(1, 32), 1);
    bitTestTotal += assertEqual(1, circularLeftShift(4, 3), 2);
    bitTestTotal += assertEqual(3, circularLeftShift(9, 4), 3);
    bitTestTotal += assertEqual(3, circularLeftShift(2147483649, 32), 4);
    //bitTesTtotal += assertEqual(3, circularLeftShift(4294967297, 33), 5);
    bitTestTotal += assertEqual(1, circularRightShift(2, 4), 6);
    bitTestTotal += assertEqual(8, circularRightShift(1, 4), 7);
    bitTestTotal += assertEqual(12, circularRightShift(9, 4), 8);
    bitTestTotal += assertEqual(3221225472, circularRightShift(2147483649, 32), 9);
    //tesTtotal += assertEqual(6442450944, circularRightShift(4294967297, 33), 10);

    if (bitTestTotal == 8) printf("All bit shifting tests pass.\n");


    //DETERMINE LIVE STATE
    int lifeTestTotal = 0;

    lifeTestTotal += assertEqual(0 ,determineLifeState(1,0) , 11);
    lifeTestTotal += assertEqual(0 ,determineLifeState(1,1) , 12);
    lifeTestTotal += assertEqual(1 ,determineLifeState(1,2) , 13);
    lifeTestTotal += assertEqual(1 ,determineLifeState(1,3) , 14);
    lifeTestTotal += assertEqual(0 ,determineLifeState(1,4) , 15);
    lifeTestTotal += assertEqual(0 ,determineLifeState(1,8) , 16);
    lifeTestTotal += assertEqual(0 ,determineLifeState(1,9) , 17);
    lifeTestTotal += assertEqual(1 ,determineLifeState(0,3) , 18);
    lifeTestTotal += assertEqual(0 ,determineLifeState(0,4) , 19);
    lifeTestTotal += assertEqual(0 ,determineLifeState(0,2) , 20);

    if (lifeTestTotal == 10) printf("All life state tests pass.\n");



    //ADD TO ROW
    int addTestTotal = 0;
    char testCount[16] = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};
    addToRow(testCount, 5, 16);

    addTestTotal += assertEqual(1 ,testCount[0] , 21);
    addTestTotal += assertEqual(0 ,testCount[1] , 22);
    addTestTotal += assertEqual(1 ,testCount[2] , 23);

    char testCount2[32] = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};
    addToRow(testCount2, 2147483649, 32);

    addTestTotal += assertEqual(1 ,testCount2[0] , 24);
    addTestTotal += assertEqual(1 ,testCount2[31] , 25);

    if (addTestTotal == 5) printf("All add to row tests pass.\n");


    //ADD THREE ROWS
    int add3TestTotal = 0;
    char test3Count[16] = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};
    addThreeRows(test3Count, 32769, 16);

    add3TestTotal += assertEqual(2, test3Count[0], 26);
    add3TestTotal += assertEqual(2, test3Count[15], 27);
    add3TestTotal += assertEqual(1, test3Count[14], 28);
    add3TestTotal += assertEqual(1, test3Count[1], 29);

    char test3Count2[32] = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};
        addThreeRows(test3Count2, 2147483649, 32);

        add3TestTotal += assertEqual(2, test3Count2[0], 30);
        add3TestTotal += assertEqual(2, test3Count2[31], 31);
        add3TestTotal += assertEqual(1, test3Count2[30], 32);
        add3TestTotal += assertEqual(1, test3Count2[1], 33);

    if (add3TestTotal == 8) printf("All add three rows tests pass.\n");


    //GENERATE ROW
    int genTestTotal = 0;


    //square
    genTestTotal += assertEqual(0, generateNewRow(0,0,3,8), 34);
    genTestTotal += assertEqual(3, generateNewRow(3,3,0,8), 35);
    genTestTotal += assertEqual(3, generateNewRow(0,3,3,8), 36);
    genTestTotal += assertEqual(0, generateNewRow(3,0,0,8), 37);

    //beehive
    genTestTotal += assertEqual(0, generateNewRow(0,0,24,8), 38);
    genTestTotal += assertEqual(24, generateNewRow(0,24,36,8), 38);
    genTestTotal += assertEqual(36, generateNewRow(24,36,24,8), 39);
    genTestTotal += assertEqual(24, generateNewRow(36,24,0,8), 40);
    genTestTotal += assertEqual(0, generateNewRow(24,0,0,8), 41);

    //blinker
    genTestTotal += assertEqual(0, generateNewRow(0,0,0,6), 42);
    genTestTotal += assertEqual(4, generateNewRow(0,0,14,6), 43);
    genTestTotal += assertEqual(4, generateNewRow(0,14,0,6), 44);
    genTestTotal += assertEqual(4, generateNewRow(14,0,0,6), 45);
    genTestTotal += assertEqual(0, generateNewRow(0,0,0,6), 46);

    if (genTestTotal == 14) printf("All generate row tests pass.\n");
}*/
/////////////////////////////////////////////////////////////////////////////////////////
//
// Write pixel stream from channel c_in to PGM image file
//
/////////////////////////////////////////////////////////////////////////////////////////
void DataOutStream(char outfname[], chanend c_in)
{
  int res;
  uchar line[ IMWD ];

  //Open PGM file
  printf( "DataOutStream: Start...\n" );
  res = _openoutpgm( outfname, IMWD, IMHT );
  if( res ) {
    printf( "DataOutStream: Error opening %s\n.", outfname );
    return;
  }

  //Compile each line of the image and write the image line-by-line
  for( int y = 0; y < IMHT; y++ ) {
    for( int x = 0; x < IMWD; x++ ) {
      c_in :> line[ x ];
    }
    _writeoutline( line, IMWD );
    printf( "DataOutStream: Line written...\n" );
  }

  //Close the PGM image
  _closeoutpgm();
  printf( "DataOutStream: Done...\n" );
  return;
}

/////////////////////////////////////////////////////////////////////////////////////////
//
// Initialise and  read orientation, send first tilt event to channel
//
/////////////////////////////////////////////////////////////////////////////////////////
void orientation( client interface i2c_master_if i2c, chanend toStateManager) {
  i2c_regop_res_t result;
  char status_data = 0;
  unsigned char tilted = 0;

  // Configure FXOS8700EQ
  result = i2c.write_reg(FXOS8700EQ_I2C_ADDR, FXOS8700EQ_XYZ_DATA_CFG_REG, 0x01);
  if (result != I2C_REGOP_SUCCESS) {
    printf("I2C write reg failed\n");
  }
  
  // Enable FXOS8700EQ
  result = i2c.write_reg(FXOS8700EQ_I2C_ADDR, FXOS8700EQ_CTRL_REG_1, 0x01);
  if (result != I2C_REGOP_SUCCESS) {
    printf("I2C write reg failed\n");
  }
  //Probe the orientation x-axis forever
  while (1) {

    //check until new orientation data is available
    do {
      status_data = i2c.read_reg(FXOS8700EQ_I2C_ADDR, FXOS8700EQ_DR_STATUS, result);
      toStateManager <: tilted;
    } while (!status_data & 0x08);

    //get new x-axis tilt value
    int x = read_acceleration(i2c, FXOS8700EQ_OUT_X_MSB);
    if (!tilted) {
        if (x>30) {
            tilted = 2;
            toStateManager <: tilted;
        }
    } else {
        if (x<30) {
            tilted = 0;
            toStateManager <: tilted;
        }
    }
  }
}

/////////////////////////////////////////////////////////////////////////////////////////
//
// Orchestrate concurrent system and start up all threads
//
/////////////////////////////////////////////////////////////////////////////////////////
int main(void) {

i2c_master_if i2c[1];               //interface to orientation
///////////////////////////////////////////////////////////////////////////////////////////////////////////
//runTests();   //TESTS
///////////////////////////////////////////////////////////////////////////////////////////////////////////
//char infname[] = "test.pgm";     //put your input image path here
//char outfname[] = "testout.pgm"; //put your output image path here*/
chan c_inIO, c_outIO;   //extend your channel definitions here
chan stateToOrientation, stateToDistributor;
par {
    on tile[0]: i2c_master(i2c, 1, p_scl, p_sda, 10);                    //server thread providing orientation data
    on tile[0]: orientation(i2c[0], stateToOrientation);                 //client thread reading orientation data
    on tile[1]: DataInStream(IN_FILE_NAME, c_inIO);                           //thread to read in a PGM image
    on tile[1]: DataOutStream(OUT_FILE_NAME, c_outIO);                        //thread to write out a PGM image
    on tile[0]: stateManager(stateToOrientation, stateToDistributor);
    on tile[0]: distributor(c_inIO, c_outIO, stateToDistributor);        //thread to coordinate work on image
  }

  return 0;
}
